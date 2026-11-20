// Package sidecar is the backend of the desktop app (`nsonline app`).
//
// One owner goroutine (Run) does everything that touches Nintendo, Coral, znca
// or the token stores: it starts and stops the presence loop and runs login,
// logout, consent, diagnostics and web service tokens as commands, with the
// loop stopped. HTTP handlers only send commands, or read copies under mu.
package sidecar

import (
	"context"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"nsonline/internal/discord"
	api "nsonline/internal/http"
	"nsonline/internal/modules/settings"
	"nsonline/internal/presence"
	"nsonline/internal/providers"
	"nsonline/internal/providers/nswitch"
	"nsonline/internal/providers/nswitch/auth"
	"nsonline/internal/providers/nswitch/client"
	"nsonline/internal/providers/nswitch/znca"
	"nsonline/internal/version"
	"nsonline/shared/i18n"
)

const (
	ObserverFile = "nso-auth.json"
	MainFile     = "nso-auth-main.json"
)

// Config: zero durations take the defaults. Tests shorten them.
type Config struct {
	DataDir    string
	Znca       znca.Config
	Apps       presence.DiscordApps
	Sink       presence.DiscordSink
	ConfigBase presence.Config
	Verbose    bool

	ClearStale   func(clientIDs []string)
	DiscordProbe func(clientID string) error
	OnShutdown   func()

	Now              func() time.Time
	HTTPTimeout      time.Duration
	CommandTimeout   time.Duration
	LoginTTL         time.Duration
	DiagnosticsEvery time.Duration
	DiscordTestFor   time.Duration
	// PollFloor: minimum gap between two polls across loop restarts. -1 disables it.
	PollFloor time.Duration
	Intervals func(settings.Settings) (inGame, idle, friends time.Duration)
	Transport http.RoundTripper
}

func (c *Config) defaults() {
	if c.Now == nil {
		c.Now = time.Now
	}

	def := func(d *time.Duration, v time.Duration) {
		if *d <= 0 {
			*d = v
		}
	}
	def(&c.HTTPTimeout, 30*time.Second)
	def(&c.CommandTimeout, 25*time.Second)
	def(&c.LoginTTL, 10*time.Minute)
	def(&c.DiagnosticsEvery, 10*time.Second)
	def(&c.DiscordTestFor, 10*time.Second)

	if c.PollFloor < 0 {
		c.PollFloor = 0
	} else if c.PollFloor == 0 {
		c.PollFloor = presence.MinInterval
	}
	if c.Intervals == nil {
		c.Intervals = func(s settings.Settings) (time.Duration, time.Duration, time.Duration) {
			sec := func(n int) time.Duration {
				return presence.AtLeast(time.Duration(n)*time.Second, presence.MinInterval)
			}
			return sec(s.IntervalSeconds), sec(s.IdleIntervalSeconds), sec(s.FriendsIntervalSeconds)
		}
	}
	if c.DiscordProbe == nil {
		c.DiscordProbe = func(id string) error {
			cl, err := discord.Connect(id)
			if err == nil {
				cl.Close()
			}
			return err
		}
	}
	if c.Transport == nil {
		c.Transport = http.DefaultTransport
	}
}

// account is one Nintendo session, owner goroutine only.
type account struct {
	name string
	path string
	*nswitch.Session
}

type pendingLogin struct {
	req     *auth.LoginRequest
	expires time.Time
}

type command struct {
	ctx  context.Context
	fn   func(ctx context.Context) error
	done chan error
}

type Supervisor struct {
	cfg      Config
	sink     *sharedSink
	settings *settings.Store
	coral    *presence.CoralTracker
	gate     *netGate
	started  time.Time

	cmds chan *command
	wake chan struct{}
	done chan struct{}

	// owner goroutine only
	obs, main *account
	mapper    *presence.Mapper
	svcStop   chan struct{}
	svcDone   chan error
	svcCancel context.CancelFunc
	nextClear bool
	nextFresh bool

	setMu sync.Mutex

	mu          sync.RWMutex
	svc         *presence.Service
	running     bool
	mainLive    bool
	set         settings.Settings
	ack         bool
	mainAck     bool
	obsTokens   presence.TokenStatus
	obsAccount  presence.Observer
	mainAccount presence.Observer
	loopErr     string
	pending     map[string]*pendingLogin
	lastDiag    time.Time
	webTokens   map[string]*providers.WebServiceOpen
	webImages   map[string]string
	webImagesAt time.Time
	webImagesOn bool
	wantClear   bool
	wantFresh   bool
	wantRestart bool
}

func New(cfg Config) (*Supervisor, error) {
	cfg.defaults()
	if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
		return nil, err
	}

	s := &Supervisor{
		cfg:       cfg,
		sink:      newSharedSink(cfg.Sink),
		settings:  settings.NewStore(cfg.DataDir),
		coral:     &presence.CoralTracker{},
		gate:      newNetGate(cfg.Transport),
		started:   cfg.Now(),
		cmds:      make(chan *command),
		wake:      make(chan struct{}, 1),
		done:      make(chan struct{}),
		mapper:    &presence.Mapper{},
		pending:   map[string]*pendingLogin{},
		webTokens: map[string]*providers.WebServiceOpen{},
	}
	s.set = s.settings.Load()
	s.obs = s.openAccount(api.AccountObserver, ObserverFile)
	s.main = s.openAccount(api.AccountMain, MainFile)
	s.refresh()
	return s, nil
}

func (s *Supervisor) openAccount(name, file string) *account {
	path := filepath.Join(s.cfg.DataDir, file)

	st, err := nswitch.LoadStore(path)
	if err != nil {
		// keep the corrupt file aside for a bug report, start logged out
		log.Printf("%s: unreadable token cache (%v), moved to %s.corrupt", file, err, file)
		_ = os.Rename(path, path+".corrupt")
		st, _ = nswitch.LoadStore(path)
	}
	return s.newAccount(name, path, st)
}

func (s *Supervisor) newAccount(name, path string, st *nswitch.Store) *account {
	c := &client.Client{HTTP: &http.Client{Timeout: s.cfg.HTTPTimeout, Transport: s.gate}, Verbose: s.cfg.Verbose}

	sess, err := nswitch.NewSession(st, c, s.cfg.Znca)
	if err != nil {
		log.Printf("znca: %v", err)
	}
	return &account{name: name, path: path, Session: sess}
}

func (s *Supervisor) zncaURL() string {
	if s.obs != nil && s.obs.Znca != nil {
		return s.obs.Znca.BaseURL
	}
	return nswitch.ZncaURL(s.cfg.Znca)
}

// refresh copies the stores' state for Status (owner goroutine, loop stopped).
func (s *Supervisor) refresh() {
	tokens, obs := s.obs.Store.Tokens()
	mainAcct := s.main.Store.Observer()
	ack := s.obs.Store.AckedFor(s.zncaURL())
	mainAck := s.main.Store.AckedFor(s.zncaURL())

	s.mu.Lock()
	s.obsTokens, s.obsAccount, s.mainAccount, s.ack, s.mainAck = tokens, obs, mainAcct, ack, mainAck
	s.mu.Unlock()
}

func (s *Supervisor) discordIDs() []string {
	seen := map[string]bool{}
	var ids []string
	for _, id := range append(s.cfg.Apps.Platforms(), s.cfg.Apps.Fallback) {
		if id != "" && !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	return ids
}

func (s *Supervisor) Run(stop <-chan struct{}) error {
	defer close(s.done)

	if s.cfg.ClearStale != nil {
		s.cfg.ClearStale(s.discordIDs())
	}
	s.restart(false, false)

	for {
		select {
		case <-stop:
			s.stopService()
			s.sink.Close()
			s.gate.use(nil)
			if t, ok := s.cfg.Transport.(interface{ CloseIdleConnections() }); ok {
				t.CloseIdleConnections()
			}
			return nil
		case c := <-s.cmds:
			s.runCommand(c)
		case <-s.wake:
			s.mu.Lock()
			clear, fresh, again := s.wantClear, s.wantFresh, s.wantRestart
			s.wantClear, s.wantFresh, s.wantRestart = false, false, false
			s.mu.Unlock()
			if again {
				s.restart(clear, fresh)
			}
		case err := <-s.svcDone:
			s.loopStopped(err)
		}
	}
}

func (s *Supervisor) runCommand(c *command) {
	if err := c.ctx.Err(); err != nil {
		c.done <- err
		return
	}

	s.stopService()
	s.gate.use(c.ctx)
	err := c.fn(c.ctx)
	s.gate.use(nil)
	s.refresh()

	clear, fresh := s.nextClear, s.nextFresh
	s.nextClear, s.nextFresh = false, false
	s.restart(clear, fresh)
	c.done <- err
}

func errTimeout() *api.Error {
	return &api.Error{Status: http.StatusGatewayTimeout, Code: "timeout", Message: i18n.T("api.error.timeout")}
}

func errStopping() *api.Error {
	return &api.Error{Status: http.StatusServiceUnavailable, Code: "shutting_down", Message: i18n.T("api.error.shuttingDown")}
}

// do runs fn on the owner goroutine, with the loop stopped, and waits.
func (s *Supervisor) do(ctx context.Context, fn func(ctx context.Context) error) error {
	ctx, cancel := context.WithTimeout(ctx, s.cfg.CommandTimeout)
	defer cancel()

	c := &command{ctx: ctx, fn: fn, done: make(chan error, 1)}
	select {
	case s.cmds <- c:
	case <-ctx.Done():
		return errTimeout()
	case <-s.done:
		return errStopping()
	}

	select {
	case err := <-c.done:
		return err
	case <-ctx.Done():
		return errTimeout()
	case <-s.done:
		return errStopping()
	}
}

func (s *Supervisor) requestRestart(clear, fresh bool) {
	s.mu.Lock()
	s.wantRestart = true
	s.wantClear = s.wantClear || clear
	s.wantFresh = s.wantFresh || fresh
	s.mu.Unlock()

	select {
	case s.wake <- struct{}{}:
	default:
	}
}

func (s *Supervisor) restart(clear, fresh bool) {
	var prev *presence.PresenceStatus
	s.mu.RLock()
	if s.svc != nil {
		prev = s.svc.Status().Presence
	}
	s.mu.RUnlock()

	s.stopService()
	if fresh {
		s.mapper = &presence.Mapper{}
		prev = nil
	}
	if clear {
		_ = s.sink.Set("", nil)
		prev = nil
	}
	s.startService(prev)
}

func (s *Supervisor) blocker() string {
	switch {
	case s.obs.Store.SessionToken == "":
		return "observer not logged in"
	case s.obs.Znca == nil:
		return "znca client not configured"
	case !s.obs.Store.AckedFor(s.zncaURL()):
		return "nxapi-znca-api consent missing"
	}
	return ""
}

func (s *Supervisor) mainReady() bool {
	return s.main.Store.SessionToken != "" && s.main.Znca != nil && s.main.Store.AckedFor(s.zncaURL())
}

func (s *Supervisor) startService(prev *presence.PresenceStatus) {
	if why := s.blocker(); why != "" {
		log.Printf("presence loop not started: %s", why)
		return
	}

	s.mu.RLock()
	set := s.set
	s.mu.RUnlock()

	interval, idle, friends := s.cfg.Intervals(set)
	obs := s.obs
	first := time.Duration(0)
	if last := s.coral.LastAttempt(); !last.IsZero() {
		first = max(0, s.cfg.PollFloor-s.cfg.Now().Sub(last))
	}

	opts := presence.Options{
		FetchFriends:    obs.Friends,
		Tokens:          obs.Store.Tokens,
		FetchPlayLog:    obs.PlayLog,
		Sink:            s.sink,
		Apps:            s.cfg.Apps,
		Target:          set.WatchTarget,
		Interval:        interval,
		Idle:            idle,
		Enabled:         set.DiscordEnabled,
		Now:             s.cfg.Now,
		ShowIdle:        set.ShowIdle,
		Mapper:          s.mapper,
		Coral:           s.coral,
		FirstDelay:      first,
		InitialPresence: prev,
	}
	if s.mainReady() {
		m := s.main
		opts.MainFriends = func() ([]providers.Friend, error) {
			fs, err := m.Friends()
			if err == nil {
				if _, ferr := m.EnsureFriendCode(); ferr != nil {
					log.Printf("main account friend code: %v", ferr)
				}
			}
			return fs, err
		}
		opts.MainAccount = m.Store.Observer
		opts.MainInterval = friends
	}

	ctx, cancel := context.WithCancel(context.Background())
	s.gate.use(ctx)
	svc := presence.New(opts)
	stop, done := make(chan struct{}), make(chan error, 1)
	go func() { done <- svc.Run(stop) }()
	s.svcStop, s.svcDone, s.svcCancel = stop, done, cancel

	s.mu.Lock()
	s.svc, s.running, s.loopErr, s.mainLive = svc, true, "", opts.MainFriends != nil
	s.mu.Unlock()
	log.Printf("presence loop started (target %q, every %s in game, %s otherwise, first poll in %s)", set.WatchTarget, interval, idle, first.Round(time.Second))
}

func (s *Supervisor) stopService() {
	if s.svcStop == nil {
		return
	}

	close(s.svcStop)
	s.svcCancel()
	err := <-s.svcDone
	s.svcStop, s.svcDone, s.svcCancel = nil, nil, nil
	s.gate.use(nil)

	s.mu.Lock()
	s.running = false
	if err != nil {
		s.loopErr = err.Error()
	}
	s.mu.Unlock()
}

// loopStopped: the loop ended on its own (fatal error). The API stays up and
// shows the error; the next command or settings change starts it again.
func (s *Supervisor) loopStopped(err error) {
	s.svcCancel()
	s.svcStop, s.svcDone, s.svcCancel = nil, nil, nil
	s.gate.use(nil)

	msg := "presence loop stopped"
	if err != nil {
		msg = err.Error()
	}
	log.Printf("presence loop stopped: %s", msg)
	_ = s.sink.Set("", nil)

	s.mu.Lock()
	s.running, s.loopErr = false, msg
	svc := s.svc
	s.mu.Unlock()
	if svc != nil {
		svc.ClearedPresence()
	}
}

func (s *Supervisor) Status() presence.Status {
	s.mu.RLock()
	svc, running, set, ack, loopErr, mainLive := s.svc, s.running, s.set, s.ack, s.loopErr, s.mainLive
	tokens, obs, mainAcct := s.obsTokens, s.obsAccount, s.mainAccount
	s.mu.RUnlock()

	var st presence.Status
	if svc != nil {
		st = svc.Status()
	} else {
		interval, idle, _ := s.cfg.Intervals(set)
		coral := s.coral.Status(s.cfg.Now(), max(interval, idle))
		pres := presence.OfflinePresence()
		st = presence.Status{Coral: &coral, Presence: &pres}
	}

	if !running {
		// the stopped loop's copies may predate the last command
		st.Tokens, st.Observer, st.Main = tokens, obs, mainAcct
		st.Watch.Error = loopErr
		st.Discord.Connected = s.sink.Connected()
	} else if !mainLive {
		st.Main = mainAcct
	}
	st.Watch.Target = set.WatchTarget
	st.Discord.Enabled = set.DiscordEnabled
	st.Setup = presence.NewSetup(ack, st.Tokens.Session, st.Main.Connected, set.WatchTarget != "")
	return st
}

func (s *Supervisor) Friends() presence.Snapshot {
	s.mu.RLock()
	svc := s.svc
	s.mu.RUnlock()

	if svc == nil {
		return presence.Snapshot{Friends: []providers.Friend{}, Source: "observer", Watchable: []presence.Account{}, PlayLog: []providers.Game{}}
	}
	return svc.Friends()
}

func (s *Supervisor) Config() presence.Config {
	set := s.Settings()
	c := s.cfg.ConfigBase
	interval, idle, _ := s.cfg.Intervals(set)

	c.WatchTarget = set.WatchTarget
	c.IntervalSeconds, c.IdleIntervalSeconds = int(interval/time.Second), int(idle/time.Second)
	c.AppVersion = client.AppVersion()
	c.Version = version.Version
	c.DiscordConfigured = s.cfg.Apps.Configured()
	c.ZncaConfigured = s.cfg.Znca.ClientID != ""
	return c
}

func (s *Supervisor) Settings() settings.Settings {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.set
}

func (s *Supervisor) SetEnabled(on bool) {
	s.setMu.Lock()
	defer s.setMu.Unlock()

	s.mu.Lock()
	s.set.DiscordEnabled = on
	set, svc := s.set, s.svc
	s.mu.Unlock()

	if err := s.settings.SaveQuiet(set); err != nil {
		log.Printf("settings: %v", err)
	}
	if svc != nil {
		svc.SetEnabled(on)
	}
}

func (s *Supervisor) PutSettings(n settings.Settings) (settings.Settings, error) {
	if err := n.Validate(); err != nil {
		return settings.Settings{}, err
	}
	if err := s.checkTarget(n.WatchTarget); err != nil {
		return settings.Settings{}, err
	}

	s.setMu.Lock()
	defer s.setMu.Unlock()

	old := s.Settings()
	if n.Language == "" {
		// the app does not send it: keep what the CLI chose
		n.Language = old.Language
	}
	if err := s.settings.Save(n); err != nil {
		log.Printf("settings: %v", err)
		return settings.Settings{}, &api.Error{Status: http.StatusInternalServerError, Code: "write_failed", Message: i18n.T("api.error.settingsWriteFailed")}
	}
	s.apply(old, n)
	return n, nil
}

func (s *Supervisor) RollbackSettings() (settings.Settings, error) {
	s.setMu.Lock()
	defer s.setMu.Unlock()

	old := s.Settings()
	n, err := s.settings.Rollback()
	if err == settings.ErrNoBackup {
		return settings.Settings{}, &api.Error{Status: http.StatusNotFound, Code: "no_backup", Message: i18n.T("api.error.noSettingsBackup")}
	}
	if err != nil {
		log.Printf("settings rollback: %v", err)
		return settings.Settings{}, &api.Error{Status: http.StatusConflict, Code: "backup_unusable", Message: i18n.T("api.error.settingsBackupUnusable")}
	}
	s.apply(old, n)
	return n, nil
}

// apply: toggles go to the running loop, anything else restarts it (a new
// target also clears Discord and the game timer).
func (s *Supervisor) apply(old, n settings.Settings) {
	s.mu.Lock()
	s.set = n
	svc := s.svc
	s.mu.Unlock()

	if svc != nil {
		if old.ShowIdle != n.ShowIdle {
			svc.SetShowIdle(n.ShowIdle)
		}
		if old.DiscordEnabled != n.DiscordEnabled {
			svc.SetEnabled(n.DiscordEnabled)
		}
	}

	target := old.WatchTarget != n.WatchTarget
	if target || old.IntervalSeconds != n.IntervalSeconds || old.IdleIntervalSeconds != n.IdleIntervalSeconds ||
		old.FriendsIntervalSeconds != n.FriendsIntervalSeconds {
		s.requestRestart(target, target)
	}
}

// checkTarget accepts anything while the friend list is unknown, then only one of its accounts.
func (s *Supervisor) checkTarget(target string) error {
	if target == "" {
		return nil
	}
	watchable := s.Friends().Watchable
	if len(watchable) == 0 {
		return nil
	}

	names := 0
	for _, a := range watchable {
		if a.NsaID == target {
			return nil
		}
		if strings.EqualFold(a.Name, target) {
			names++
		}
	}

	switch names {
	case 1:
		return nil
	case 0:
		return &settings.FieldError{Field: "watchTarget", Code: "unknown_target", Message: i18n.T("api.error.unknownTarget")}
	default:
		return &settings.FieldError{Field: "watchTarget", Code: "ambiguous_target", Message: i18n.T("api.error.ambiguousTarget", i18n.Args{"count": names})}
	}
}

func (s *Supervisor) Shutdown() {
	if s.cfg.OnShutdown != nil {
		s.cfg.OnShutdown()
	}
}
