package presence

import (
	"log"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"nsonline/internal/discord"
	"nsonline/internal/providers"
)

type (
	Observer    = providers.Observer
	TokenStatus = providers.TokenStatus
)

type DiscordStatus struct {
	Enabled   bool `json:"enabled"`
	Connected bool `json:"connected"`
}

type WatchStatus struct {
	Target   string     `json:"target"`
	LastPoll *time.Time `json:"lastPoll"`
	Error    string     `json:"error,omitempty"`
}

// Status is GET /api/status. Pointers with omitempty: absent means an older backend.
type Status struct {
	Observer Observer      `json:"observer"`
	Main     Observer      `json:"main"`
	Tokens   TokenStatus   `json:"tokens"`
	Discord  DiscordStatus `json:"discord"`
	Watch    WatchStatus   `json:"watch"`

	Setup    *SetupStatus    `json:"setup,omitempty"`
	Coral    *CoralStatus    `json:"coral,omitempty"`
	Presence *PresenceStatus `json:"presence,omitempty"`
}

type SetupStatus struct {
	ThirdPartyAck    bool `json:"thirdPartyAck"`
	ObserverLoggedIn bool `json:"observerLoggedIn"`
	MainLoggedIn     bool `json:"mainLoggedIn"`
	TargetSet        bool `json:"targetSet"`
	Complete         bool `json:"complete"`
}

func NewSetup(ack, observer, main, target bool) *SetupStatus {
	return &SetupStatus{ThirdPartyAck: ack, ObserverLoggedIn: observer, MainLoggedIn: main, TargetSet: target, Complete: ack && observer && target}
}

type Account struct {
	NsaID string `json:"nsaId"`
	Name  string `json:"name"`
}

// Snapshot is GET /api/friends. Friends are the main account's when it is
// logged in, else the observer's. Watchable is always the observer's list.
type Snapshot struct {
	Friends   []providers.Friend `json:"friends"`
	Source    string             `json:"source"`
	UpdatedAt *time.Time         `json:"updatedAt"`
	Error     string             `json:"error,omitempty"`
	Watchable []Account          `json:"watchable"`
	Watched   *providers.Friend  `json:"watched"`
	PlayLog   []providers.Game   `json:"playLog"`
}

const playLogEvery = 10 * time.Minute

// mainStartDelay keeps the two accounts' first polls apart: one znca request at a time.
const mainStartDelay = 3 * time.Second

// Config is GET /api/config: never a secret.
type Config struct {
	WatchTarget         string `json:"watchTarget"`
	DiscordSwitch2ID    string `json:"discordSwitch2Id"`
	DiscordSwitchID     string `json:"discordSwitchId"`
	DiscordDefaultID    string `json:"discordDefaultId"`
	IntervalSeconds     int    `json:"intervalSeconds"`
	IdleIntervalSeconds int    `json:"idleIntervalSeconds"`
	ZncaClientID        string `json:"zncaClientId"`
	ZncaAuth            string `json:"zncaAuth"`
	ZncaHasSecret       bool   `json:"zncaHasSecret"`
	Contact             string `json:"contact"`
	AppVersion          string `json:"appVersion"`
	Version             string `json:"version"`
	DiscordConfigured   bool   `json:"discordConfigured"`
	ZncaConfigured      bool   `json:"zncaConfigured"`
}

type DiscordSink interface {
	Sink
	Connected() bool
}

// Options: every func is called from the poll goroutines only.
type Options struct {
	FetchFriends func() ([]providers.Friend, error)
	MainFriends  func() ([]providers.Friend, error)
	MainAccount  func() Observer
	MainInterval time.Duration
	FetchPlayLog func(nsaID string) ([]providers.Game, error)
	Tokens       func() (TokenStatus, Observer)
	Sink         DiscordSink
	Apps         DiscordApps
	Target       string
	Interval     time.Duration
	Idle         time.Duration
	Config       Config
	Enabled      bool
	Now          func() time.Time

	ShowIdle        bool
	Mapper          *Mapper
	Coral           *CoralTracker
	FirstDelay      time.Duration
	InitialPresence *PresenceStatus
}

// Service runs the presence loop and keeps the snapshot served to the app.
// Only its goroutines call the providers; readers get copies under mu.
type Service struct {
	opts     Options
	watcher  *Watcher
	enabled  atomic.Bool
	showIdle atomic.Bool
	online   atomic.Bool
	coral    *CoralTracker

	mu          sync.RWMutex
	snapshot    Snapshot
	watchable   []Account
	watched     *providers.Friend
	playLog     []providers.Game
	playLogAt   time.Time
	playLogGame string
	main        Observer
	tokens      TokenStatus
	observer    Observer
	lastPoll    *time.Time
	lastErr     string
	presence    PresenceStatus
}

func New(opts Options) *Service {
	if opts.Now == nil {
		opts.Now = time.Now
	}

	s := &Service{opts: opts, coral: opts.Coral, presence: OfflinePresence()}
	if s.coral == nil {
		s.coral = &CoralTracker{}
	}
	if opts.InitialPresence != nil {
		s.presence = *opts.InitialPresence
	}
	s.enabled.Store(opts.Enabled)
	s.showIdle.Store(opts.ShowIdle)
	s.tokens, s.observer = opts.Tokens()
	if opts.MainAccount != nil {
		s.main = opts.MainAccount()
	}

	s.watcher = &Watcher{
		Fetch:      s.poll,
		Sink:       gatedSink{s},
		Apps:       opts.Apps,
		Interval:   opts.Interval,
		Idle:       opts.Idle,
		Now:        opts.Now,
		ShowIdle:   s.showIdle.Load,
		Player:     s.player,
		Mapper:     opts.Mapper,
		FirstDelay: opts.FirstDelay,
		OnSync:     s.onSync,
	}
	return s
}

func (s *Service) Run(stop <-chan struct{}) error {
	var wg sync.WaitGroup
	mainStop := make(chan struct{})
	if s.opts.MainFriends != nil {
		wg.Add(1)
		go func() { defer wg.Done(); s.mainLoop(mainStop) }()
	}

	err := s.watcher.Run(stop)
	close(mainStop)
	wg.Wait()
	return err
}

func (s *Service) onSync(p providers.Presence, a *discord.Activity, clientID string) {
	if !s.enabled.Load() {
		a, clientID = nil, ""
	}

	st := presenceStatus(p, a, clientID, s.opts.Apps)
	s.mu.Lock()
	s.presence = st
	s.mu.Unlock()
}

func (s *Service) SetShowIdle(on bool) {
	s.showIdle.Store(on)
	s.watcher.Resync()
}

func (s *Service) SetEnabled(on bool) {
	s.enabled.Store(on)
	s.watcher.Resync()
}

func (s *Service) ClearedPresence() {
	s.mu.Lock()
	s.presence = OfflinePresence()
	s.mu.Unlock()
}

func (s *Service) mainLoop(stop <-chan struct{}) {
	timer := time.NewTimer(mainStartDelay)
	defer timer.Stop()

	failures := 0
	for {
		select {
		case <-stop:
			return
		case <-timer.C:
		}

		friends, err := s.opts.MainFriends()
		now := s.opts.Now()
		var account Observer
		if s.opts.MainAccount != nil {
			account = s.opts.MainAccount()
		}

		s.mu.Lock()
		s.main = account
		if err != nil {
			s.snapshot.Error = err.Error()
		} else {
			s.snapshot = Snapshot{Friends: friends, Source: "main", UpdatedAt: &now}
		}
		s.mu.Unlock()

		next := s.opts.MainInterval
		if err != nil {
			failures++
			next = Backoff(s.opts.MainInterval, failures, providers.RetryAfter(err))
			log.Printf("main account friends: %v (retry in %s)", err, next)
		} else {
			failures = 0
		}
		timer.Reset(next)
	}
}

func (s *Service) Status() Status {
	s.mu.RLock()
	defer s.mu.RUnlock()

	coral := s.coral.Status(s.opts.Now(), max(s.opts.Interval, s.opts.Idle))
	pres := s.presence
	if pres.Game != nil {
		g := *pres.Game
		pres.Game = &g
	}

	return Status{
		Observer: s.observer,
		Main:     s.main,
		Tokens:   s.tokens,
		Discord:  DiscordStatus{Enabled: s.enabled.Load(), Connected: s.online.Load()},
		Watch:    WatchStatus{Target: s.opts.Target, LastPoll: s.lastPoll, Error: s.lastErr},
		Setup:    NewSetup(s.tokens.ThirdPartyAck, s.tokens.Session, s.main.Connected, s.opts.Target != ""),
		Coral:    &coral,
		Presence: &pres,
	}
}

func (s *Service) Friends() Snapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()

	snap := s.snapshot
	snap.Watchable, snap.Watched, snap.PlayLog = s.watchable, s.watched, s.playLog
	return snap
}

func (s *Service) Config() Config { return s.opts.Config }

// poll is the Watcher's Fetch. A missing target only means "nothing to show".
func (s *Service) poll() (providers.Presence, string, error) {
	start := time.Now()
	friends, err := s.opts.FetchFriends()
	latency := time.Since(start)
	tokens, observer := s.opts.Tokens()
	now := s.opts.Now()
	s.coral.Record(now, latency, err)

	s.mu.Lock()
	s.tokens, s.observer, s.lastPoll = tokens, observer, &now
	switch {
	case providers.IsCanceled(err):
	case err != nil:
		s.lastErr = err.Error()
	default:
		s.lastErr = ""
		s.watchable = make([]Account, len(friends))
		for i, f := range friends {
			s.watchable[i] = Account{NsaID: f.NsaID, Name: f.Name}
		}
		if s.opts.MainFriends == nil {
			s.snapshot = Snapshot{Friends: friends, Source: "observer", UpdatedAt: &now}
		}
	}
	s.mu.Unlock()

	if err != nil {
		return providers.Presence{}, "", err
	}

	var watched *providers.Friend
	if s.opts.Target != "" {
		if f, ferr := providers.FindFriend(friends, s.opts.Target); ferr == nil {
			cp := *f
			watched = &cp
		}
	}
	s.mu.Lock()
	s.watched = watched
	s.mu.Unlock()

	if watched == nil {
		return providers.Presence{}, "", nil
	}
	s.refreshPlayLog(watched, now)
	return watched.Presence, watched.Name, nil
}

// refreshPlayLog runs at start, when the game changes and every playLogEvery at most.
func (s *Service) refreshPlayLog(watched *providers.Friend, now time.Time) {
	if s.opts.FetchPlayLog == nil {
		return
	}

	game := watched.Presence.Game.Name
	if !s.playLogAt.IsZero() && game == s.playLogGame && now.Sub(s.playLogAt) < playLogEvery {
		return
	}
	s.playLogAt, s.playLogGame = now, game

	games, err := s.opts.FetchPlayLog(watched.NsaID)
	if err != nil {
		log.Printf("play log of %s: %v (retry in %s)", watched.Name, err, playLogEvery)
		return
	}

	s.mu.Lock()
	s.playLog = games
	s.mu.Unlock()
}

// player: friend codes are not in Friend/List, only known for our own accounts.
func (s *Service) player() Player {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.watched == nil {
		return Player{}
	}

	p := Player{Name: s.watched.Name}
	if strings.HasPrefix(s.watched.ImageURI, "https://") {
		p.AvatarURL = s.watched.ImageURI
	}
	for _, own := range []Observer{s.main, s.observer} {
		if own.NsaID != "" && own.NsaID == s.watched.NsaID {
			p.FriendCode = own.FriendCode
		}
	}
	return p
}

// gatedSink clears Discord while the presence is disabled.
type gatedSink struct{ s *Service }

func (g gatedSink) Set(clientID string, a *discord.Activity) error {
	if !g.s.enabled.Load() {
		clientID, a = "", nil
	}

	err := g.s.opts.Sink.Set(clientID, a)
	g.s.online.Store(g.s.opts.Sink.Connected())
	return err
}
