package sidecar

import (
	"context"
	"errors"
	"io/fs"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"nsonline/internal/discord"
	api "nsonline/internal/http"
	"nsonline/internal/modules/diagnostics"
	"nsonline/internal/presence"
	"nsonline/internal/providers/nswitch"
	"nsonline/internal/providers/nswitch/auth"
	"nsonline/internal/providers/nswitch/client"
	"nsonline/internal/version"
	"nsonline/shared/i18n"
)

// Errors are built per call so their message follows the locale.
func badAccount() *api.Error {
	return &api.Error{Status: http.StatusBadRequest, Code: "invalid_account", Field: "account", Message: i18n.T("api.error.unknownAccount")}
}

func loginExpired() *api.Error {
	return &api.Error{Status: http.StatusGone, Code: "login_expired", Message: i18n.T("api.error.loginExpired")}
}

func upstreamError() *api.Error {
	return &api.Error{Status: http.StatusBadGateway, Code: "upstream_error", Message: i18n.T("api.error.upstream")}
}

func writeFailed(key string) *api.Error {
	return &api.Error{Status: http.StatusInternalServerError, Code: "write_failed", Message: i18n.T(key)}
}

// upstream: a rejected code (expired, already used) is login_expired, anything else is upstream's fault.
func upstream(ctx context.Context, err error) error {
	var ae *client.APIError
	switch {
	case ctx.Err() != nil:
		return errTimeout()
	case errors.As(err, &ae) && ae.Status >= 400 && ae.Status < 500 && ae.Status != http.StatusTooManyRequests:
		return loginExpired()
	case errors.As(err, &ae) && ae.RetryAfter > 0:
		e := upstreamError()
		e.RetryAfter = ae.RetryAfter
		return e
	}
	return upstreamError()
}

func (s *Supervisor) account(name string) *account {
	if name == api.AccountMain {
		return s.main
	}
	return s.obs
}

func (s *Supervisor) Ack(ctx context.Context) (presence.Status, error) {
	err := s.do(ctx, func(context.Context) error {
		url := s.zncaURL()
		for _, a := range []*account{s.obs, s.main} {
			a.Store.AckThirdParty(url)
			if err := a.Store.Save(); err != nil {
				log.Printf("consent: %v", err)
				return writeFailed("api.error.consentWriteFailed")
			}
		}
		log.Printf("nxapi-znca-api consent recorded for %s", url)
		return nil
	})
	if err != nil {
		return presence.Status{}, err
	}
	return s.Status(), nil
}

// LoginStart is local: the PKCE verifier stays in memory, one pending login per account.
func (s *Supervisor) LoginStart(account string) (api.LoginStart, error) {
	if account != api.AccountObserver && account != api.AccountMain {
		return api.LoginStart{}, badAccount()
	}

	req, err := auth.NewLoginRequest()
	if err != nil {
		return api.LoginStart{}, err
	}

	s.mu.Lock()
	s.pending[account] = &pendingLogin{req: req, expires: s.cfg.Now().Add(s.cfg.LoginTTL)}
	s.mu.Unlock()
	return api.LoginStart{URL: req.URL, RedirectPrefix: auth.RedirectURI}, nil
}

func (s *Supervisor) LoginComplete(ctx context.Context, account, redirect string) (presence.Status, error) {
	if account != api.AccountObserver && account != api.AccountMain {
		return presence.Status{}, badAccount()
	}

	s.mu.Lock()
	p := s.pending[account]
	if p != nil && s.cfg.Now().After(p.expires) {
		delete(s.pending, account)
		p = nil
	}
	s.mu.Unlock()
	if p == nil {
		return presence.Status{}, loginExpired()
	}

	link := strings.TrimSpace(redirect)
	if !strings.HasPrefix(link, auth.RedirectURI) {
		return presence.Status{}, &api.Error{Status: http.StatusBadRequest, Code: "invalid_redirect", Field: "redirect",
			Message: i18n.T("api.error.redirectExpected", i18n.Args{"prefix": auth.RedirectURI})}
	}
	code, err := p.req.ParseRedirect(link)
	if err != nil {
		return presence.Status{}, &api.Error{Status: http.StatusBadRequest, Code: "invalid_redirect", Field: "redirect",
			Message: i18n.T("api.error.redirectInvalid", i18n.Args{"error": err.Error()})}
	}

	err = s.do(ctx, func(ctx context.Context) error {
		a := s.account(account)
		token, err := auth.ExchangeSessionToken(a.Client, p.req, code)
		if err != nil {
			log.Printf("login (%s): %v", account, err)
			return upstream(ctx, err)
		}
		if err := a.Store.ResetSession(token); err != nil {
			log.Printf("login (%s): %v", account, err)
			return writeFailed("api.error.sessionWriteFailed")
		}

		log.Printf("login (%s): session saved", account)
		s.forgetWebTokens(account)
		if account == api.AccountObserver {
			s.coral.Reset()
			s.nextClear, s.nextFresh = true, true
		}
		return nil
	})

	var ae *api.Error
	if err == nil || (errors.As(err, &ae) && ae.Code == "login_expired") {
		s.mu.Lock()
		if s.pending[account] == p {
			delete(s.pending, account)
		}
		s.mu.Unlock()
	}
	if err != nil {
		return presence.Status{}, err
	}
	return s.Status(), nil
}

// Logout deletes the token cache but keeps the consent, and clears Discord for the observer.
func (s *Supervisor) Logout(ctx context.Context, which string) (presence.Status, error) {
	var accounts []string
	switch which {
	case api.AccountObserver, api.AccountMain:
		accounts = []string{which}
	case api.AccountAll:
		accounts = []string{api.AccountObserver, api.AccountMain}
	default:
		return presence.Status{}, badAccount()
	}

	err := s.do(ctx, func(context.Context) error {
		for _, name := range accounts {
			if name == api.AccountObserver {
				_ = s.sink.Set("", nil)
			}

			fresh, err := s.forget(s.account(name))
			if err != nil {
				log.Printf("logout (%s): %v", name, err)
				return writeFailed("api.error.sessionDeleteFailed")
			}

			if name == api.AccountObserver {
				s.obs = fresh
				s.coral.Reset()
				s.nextFresh = true
				s.mu.Lock()
				s.svc, s.loopErr = nil, ""
				s.mu.Unlock()
			} else {
				s.main = fresh
			}

			s.forgetWebTokens(name)
			s.mu.Lock()
			delete(s.pending, name)
			s.mu.Unlock()
			log.Printf("logout (%s): token cache deleted", name)
		}
		return nil
	})
	if err != nil {
		return presence.Status{}, err
	}
	return s.Status(), nil
}

func (s *Supervisor) forget(a *account) (*account, error) {
	ack, url := a.Store.ThirdPartyAck, a.Store.ThirdPartyAckURL
	if err := os.Remove(a.path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, err
	}

	st, err := nswitch.LoadStore(a.path)
	if err != nil {
		return nil, err
	}
	if ack {
		st.ThirdPartyAck, st.ThirdPartyAckURL = ack, url
		if err := st.Save(); err != nil {
			return nil, err
		}
	}
	return s.newAccount(a.name, a.path, st), nil
}

func TestActivity() *discord.Activity {
	return &discord.Activity{Type: discord.Playing, Details: i18n.T("discord.test.details"), State: i18n.T("discord.test.state")}
}

func (s *Supervisor) TestDiscord() api.DiscordTest {
	id := s.cfg.Apps.ForPlatform(0)
	if id == "" {
		return api.DiscordTest{Error: i18n.T("api.error.noDiscordApp")}
	}

	if err := s.sink.ShowTest(id, TestActivity(), s.cfg.DiscordTestFor); err != nil {
		return api.DiscordTest{DiscordRunning: s.sink.Connected(), Error: err.Error()}
	}
	return api.DiscordTest{OK: true, DiscordRunning: true}
}

// Diagnostics runs one fresh poll and a Discord ping as an owner command, at most once per DiagnosticsEvery.
func (s *Supervisor) Diagnostics(ctx context.Context) (diagnostics.Report, error) {
	now := s.cfg.Now()

	s.mu.Lock()
	if !s.lastDiag.IsZero() {
		if wait := s.cfg.DiagnosticsEvery - now.Sub(s.lastDiag); wait > 0 {
			s.mu.Unlock()
			return diagnostics.Report{}, &api.Error{Status: http.StatusTooManyRequests, Code: "rate_limited",
				Message: i18n.T("api.error.diagnosticsTooSoon"), RetryAfter: wait}
		}
	}
	s.lastDiag = now
	s.mu.Unlock()

	var rep diagnostics.Report
	err := s.do(ctx, func(context.Context) error {
		rep = diagnostics.Run(s.probes(), s.cfg.Now())
		return nil
	})
	return rep, err
}

func (s *Supervisor) probes() diagnostics.Probes {
	obs := s.obs
	p := diagnostics.Probes{
		Version:    version.Version,
		Uptime:     s.cfg.Now().Sub(s.started),
		DiscordApp: s.cfg.Apps.ForPlatform(0) != "",
	}

	if obs.Store.SessionToken != "" {
		p.Account = func() error {
			_, err := obs.EnsureAccount()
			return err
		}
	}

	switch {
	case obs.Znca == nil:
		p.ZncaSkipped = i18n.T("diag.znca.notConfigured")
	case !obs.Store.AckedFor(s.zncaURL()):
		p.ZncaSkipped = i18n.T("diag.znca.consentRequired")
	default:
		p.Znca = obs.Znca.EnsureToken
	}

	p.Coral = func() (int, error) {
		start := time.Now()
		fs, err := obs.Friends()
		s.coral.Record(s.cfg.Now(), time.Since(start), err)
		return len(fs), err
	}

	if id := s.cfg.Apps.ForPlatform(0); id != "" {
		p.Discord = func() error { return s.sink.Probe(id, s.cfg.DiscordProbe) }
	}
	return p
}
