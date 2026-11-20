package nswitch

import (
	"errors"
	"strings"

	"nsonline/internal/providers"
	"nsonline/internal/providers/nswitch/auth"
	"nsonline/internal/providers/nswitch/client"
	"nsonline/internal/providers/nswitch/coral"
	"nsonline/internal/providers/nswitch/znca"
	"nsonline/internal/secrets"
)

const Kind = "nswitch"

// presence.platform values
const (
	PlatformSwitch  = 1
	PlatformSwitch2 = 2
)

func init() { providers.Register(New(znca.Config{}, false)) }

type Provider struct {
	Znca    znca.Config
	Verbose bool
}

func New(cfg znca.Config, verbose bool) *Provider { return &Provider{Znca: cfg, Verbose: verbose} }

func (p *Provider) Kind() string { return Kind }

func (p *Provider) Platforms() []providers.Platform {
	return []providers.Platform{
		{ID: PlatformSwitch, Name: "Nintendo Switch", Asset: "switch"},
		{ID: PlatformSwitch2, Name: "Nintendo Switch 2", Asset: "switch2"},
	}
}

func (p *Provider) DiscordApp(platform int) string {
	switch platform {
	case PlatformSwitch:
		return secrets.Get("DISCORD_CLIENT_ID_SWITCH")
	case PlatformSwitch2:
		return secrets.Get("DISCORD_CLIENT_ID_SWITCH2")
	}
	return ""
}

func (p *Provider) WebServices() []providers.WebService {
	var out []providers.WebService
	for _, w := range webServices {
		out = append(out, w.WebService)
	}
	return out
}

func (p *Provider) Open(path string) (providers.Session, error) {
	st, err := LoadStore(path)
	if err != nil {
		return nil, err
	}
	return NewSession(st, client.New(p.Verbose), p.Znca)
}

func (s *Session) LoggedIn() bool { return s.Store.SessionToken != "" }

func (s *Session) StartLogin() (*providers.Login, error) {
	req, err := auth.NewLoginRequest()
	if err != nil {
		return nil, err
	}
	return &providers.Login{URL: req.URL, RedirectPrefix: auth.RedirectURI, State: req}, nil
}

func (s *Session) FinishLogin(l *providers.Login, redirect string) error {
	req, ok := l.State.(*auth.LoginRequest)
	if !ok {
		return errors.New("login was not started by this provider")
	}

	code, err := req.ParseRedirect(redirect)
	if err != nil {
		return err
	}
	token, err := auth.ExchangeSessionToken(s.Client, req, code)
	if err != nil {
		return err
	}
	return s.Store.ResetSession(token)
}

func (s *Session) Friends() ([]providers.Friend, error) {
	raw, err := s.FriendsRaw()
	if err != nil {
		return nil, err
	}
	return coral.ParseFriends(raw)
}

func (s *Session) Presence(target string) (providers.Presence, string, error) {
	friends, err := s.Friends()
	if err != nil {
		return providers.Presence{}, "", err
	}

	f, err := providers.FindTarget(friends, target)
	if err != nil {
		return providers.Presence{}, "", err
	}
	return f.Presence, f.Name, nil
}

// ZncaURL is the service the third-party consent is given for.
func ZncaURL(cfg znca.Config) string {
	u := cfg.BaseURL
	if u == "" {
		u = znca.DefaultURL
	}
	if !strings.HasSuffix(u, "/") {
		u += "/"
	}
	return u
}
