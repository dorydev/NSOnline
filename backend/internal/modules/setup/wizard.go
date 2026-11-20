// Package setup is the interactive CLI: `nsonline setup` (wizard) and
// `nsonline config` (settings menu). Both use the app's data dir and files.
package setup

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"nsonline/internal/modules/settings"
	"nsonline/internal/providers"
	"nsonline/internal/providers/nswitch"
	"nsonline/internal/providers/nswitch/auth"
	"nsonline/internal/providers/nswitch/client"
	"nsonline/internal/providers/nswitch/znca"
	"nsonline/shared/i18n"
)

const (
	ObserverFile = "nso-auth.json"
	MainFile     = "nso-auth-main.json"
	steps        = 7
)

type Deps struct {
	In      io.Reader
	Out     io.Writer
	DataDir string
	Znca    znca.Config

	Client      func() *client.Client
	OpenBrowser func(url string)
	// TestDiscord shows a test activity. Nil when no Discord app is configured.
	TestDiscord func() error
	Friends     func(s *nswitch.Session) ([]providers.Friend, error)
}

func (d *Deps) defaults() {
	if d.Client == nil {
		d.Client = func() *client.Client { return client.New(false) }
	}
	if d.OpenBrowser == nil {
		d.OpenBrowser = func(string) {}
	}
	if d.Friends == nil {
		d.Friends = func(s *nswitch.Session) ([]providers.Friend, error) { return s.Friends() }
	}
}

func (d Deps) open(file string) (*nswitch.Session, error) {
	st, err := nswitch.LoadStore(filepath.Join(d.DataDir, file))
	if err != nil {
		return nil, err
	}

	s, err := nswitch.NewSession(st, d.Client(), d.Znca)
	if err != nil {
		return s, err
	}
	return s, nil
}

type wizard struct {
	*term
	d        Deps
	obs      *nswitch.Session
	main     *nswitch.Session
	zncaURL  string
	draft    settings.Settings
	settings *settings.Store
}

func (w *wizard) step(n int, key string) {
	fmt.Fprintln(w.out)
	w.say("cli.setup.step", i18n.Args{"n": n, "total": steps, "title": i18n.T(key)})
}

func (w *wizard) consent() error {
	w.step(1, "cli.setup.consentTitle")
	if w.obs.Store.AckedFor(w.zncaURL) {
		w.say("cli.setup.consentDone")
		return nil
	}

	a, err := w.line(i18n.T("cli.consent.prompt", i18n.Args{"url": w.zncaURL, "yes": i18n.T("cli.consent.yes")}))
	if err != nil {
		return err
	}
	if strings.ToLower(a) != "yes" && strings.ToLower(a) != strings.ToLower(i18n.T("cli.consent.yes")) {
		w.say("cli.consent.aborted")
		return ErrCanceled
	}

	w.obs.Store.AckThirdParty(w.zncaURL)
	w.main.Store.AckThirdParty(w.zncaURL)
	return nil
}

func (w *wizard) login(s *nswitch.Session) error {
	req, err := auth.NewLoginRequest()
	if err != nil {
		return err
	}

	w.say("cli.login.instructions", i18n.Args{"url": req.URL, "prefix": auth.RedirectURI})
	w.d.OpenBrowser(req.URL)

	for {
		link, err := w.line(">")
		if err != nil {
			return err
		}

		code, err := req.ParseRedirect(link)
		if err != nil {
			w.say("cli.setup.badLink", i18n.Args{"error": err.Error()})
			continue
		}

		token, err := auth.ExchangeSessionToken(s.Client, req, code)
		if err != nil {
			return fmt.Errorf("%s: %w", i18n.T("cli.setup.loginFailed"), err)
		}
		if err := s.Store.ResetSession(token); err != nil {
			return err
		}
		w.say("cli.setup.loginSaved", i18n.Args{"file": s.Store.Path()})
		return nil
	}
}

func (w *wizard) observer() error {
	w.step(2, "cli.setup.observerTitle")
	w.say("cli.setup.observerHelp")

	if w.obs.LoggedIn() {
		again, err := w.yesNo(i18n.T("cli.setup.loggedInAgain"), false)
		if err != nil || !again {
			return err
		}
	}
	return w.login(w.obs)
}

func (w *wizard) mainAccount() error {
	w.step(3, "cli.setup.mainTitle")
	w.say("cli.setup.mainHelp")

	key := "cli.setup.mainAsk"
	if w.main.LoggedIn() {
		key = "cli.setup.loggedInAgain"
	}
	yes, err := w.yesNo(i18n.T(key), false)
	if err != nil || !yes {
		return err
	}
	return w.login(w.main)
}

func (w *wizard) manualTarget() error {
	for {
		t, err := w.line(i18n.T("cli.setup.targetManual", i18n.Args{"current": w.draft.WatchTarget}))
		if err != nil {
			return err
		}
		if t == "" {
			return nil
		}

		next := w.draft
		next.WatchTarget = t
		if err := next.Validate(); err != nil {
			w.say("cli.setup.invalid", i18n.Args{"error": err.Error()})
			continue
		}
		w.draft = next
		return nil
	}
}

func (w *wizard) target() error {
	w.step(4, "cli.setup.targetTitle")

	if !w.obs.LoggedIn() || w.obs.Znca == nil {
		w.say("cli.setup.targetNoList")
		return w.manualTarget()
	}

	w.say("cli.setup.readingFriends")
	friends, err := w.d.Friends(w.obs)
	if err != nil {
		w.say("cli.setup.friendsFailed", i18n.Args{"error": err.Error()})
		return w.manualTarget()
	}
	if len(friends) == 0 {
		w.say("cli.setup.noFriends")
		return w.manualTarget()
	}

	w.say("cli.setup.pickFriend")
	for i, f := range friends {
		fmt.Fprintf(w.out, "  %2d) %s  (%s)\n", i+1, f.Name, f.NsaID)
	}
	w.say("cli.setup.pickKeep", i18n.Args{"current": w.draft.WatchTarget})

	n, err := w.number(">", len(friends), 0, true)
	if err != nil || n == 0 {
		return err
	}
	w.draft.WatchTarget = friends[n-1].NsaID
	return nil
}

func (w *wizard) discord() error {
	w.step(5, "cli.setup.discordTitle")
	if w.d.TestDiscord == nil {
		w.say("cli.setup.discordMissing")
		return nil
	}

	yes, err := w.yesNo(i18n.T("cli.setup.discordAsk"), true)
	if err != nil || !yes {
		return err
	}

	if err := w.d.TestDiscord(); err != nil {
		w.say("cli.setup.discordFailed", i18n.Args{"error": err.Error()})
		return nil
	}
	w.say("cli.setup.discordOK")
	return nil
}

func (w *wizard) preferences() error {
	w.step(6, "cli.setup.prefsTitle")

	var err error
	d := &w.draft
	if d.IntervalSeconds, err = w.seconds(i18n.T("cli.config.interval"), d.IntervalSeconds, settings.MinSeconds, settings.MaxSeconds); err != nil {
		return err
	}
	if d.IdleIntervalSeconds, err = w.seconds(i18n.T("cli.config.idleInterval"), d.IdleIntervalSeconds, settings.MinSeconds, settings.MaxSeconds); err != nil {
		return err
	}
	if d.FriendsIntervalSeconds, err = w.seconds(i18n.T("cli.config.friendsInterval"), d.FriendsIntervalSeconds, settings.MinSeconds, settings.MaxSeconds); err != nil {
		return err
	}
	if d.ShowIdle, err = w.yesNo(i18n.T("cli.config.showIdle"), d.ShowIdle); err != nil {
		return err
	}
	d.Language, err = w.language(d.Language)
	return err
}

func (w *wizard) summary() (bool, error) {
	w.step(7, "cli.setup.summaryTitle")
	printSettings(w.term, w.draft, false)

	w.say("cli.setup.summaryObserver", i18n.Args{"value": accountLabel(w.obs)})
	w.say("cli.setup.summaryMain", i18n.Args{"value": accountLabel(w.main)})
	return w.yesNo(i18n.T("cli.setup.saveAsk"), true)
}

func accountLabel(s *nswitch.Session) string {
	if !s.LoggedIn() {
		return i18n.T("cli.setup.notLoggedIn")
	}
	if name := s.Store.Observer().Name; name != "" {
		return name
	}
	return i18n.T("cli.setup.loggedIn")
}

func (w *wizard) save() error {
	for _, s := range []*nswitch.Session{w.obs, w.main} {
		if s.Store.AckedFor(w.zncaURL) {
			if err := s.Store.Save(); err != nil {
				return err
			}
		}
	}
	if err := w.settings.Save(w.draft); err != nil {
		return err
	}
	w.say("cli.setup.saved")
	return nil
}

// Wizard runs `nsonline setup`. Settings are written only at the last step:
// an EOF or a "no" there leaves settings.json untouched. A login is saved as
// soon as it succeeds.
func Wizard(d Deps) error {
	d.defaults()
	t := newTerm(d.In, d.Out)

	obs, err := d.open(ObserverFile)
	if obs == nil {
		return err
	}
	if err != nil {
		t.say("cli.setup.zncaMissing", i18n.Args{"error": err.Error()})
	}
	main, _ := d.open(MainFile)
	if main == nil {
		return fmt.Errorf("%s: unreadable token cache", MainFile)
	}

	store := settings.NewStore(d.DataDir)
	w := &wizard{term: t, d: d, obs: obs, main: main, zncaURL: nswitch.ZncaURL(d.Znca), draft: store.Load(), settings: store}

	if out, ok := d.Out.(*os.File); ok && isTerminal(out) {
		if m := detectColor(os.Getenv); m != noColor {
			newHeader(i18n.T("cli.setup.header"), i18n.T("cli.setup.subtitle"), "").write(out, m)
			fmt.Fprintln(out)
		}
	}
	t.say("cli.setup.welcome")
	if d.Znca.ClientID == "" {
		t.say("cli.setup.zncaMissing", i18n.Args{"error": "NXAPI_ZNCA_API_CLIENT_ID"})
	}

	for _, run := range []func() error{w.consent, w.observer, w.mainAccount, w.target, w.discord, w.preferences} {
		if err := run(); err != nil {
			return err
		}
	}

	ok, err := w.summary()
	if err != nil {
		return err
	}
	if !ok {
		return ErrCanceled
	}
	return w.save()
}
