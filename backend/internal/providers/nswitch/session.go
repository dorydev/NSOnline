package nswitch

import (
	"encoding/json"
	"errors"
	"strings"

	"nsonline/internal/providers"
	"nsonline/internal/providers/nswitch/auth"
	"nsonline/internal/providers/nswitch/client"
	"nsonline/internal/providers/nswitch/coral"
	"nsonline/internal/providers/nswitch/znca"
)

var ErrNotLoggedIn = errors.New("no session token: run `nsonline login` first")

// Session is one Nintendo Account. Use it from one goroutine only.
type Session struct {
	Store  *Store
	Client *client.Client
	Znca   *znca.Znca // nil when the znca client is not configured
}

func NewZnca(c *client.Client, st *Store, cfg znca.Config) (*znca.Znca, error) {
	load := func() *znca.Token { return st.Znca }
	save := func(t *znca.Token) error {
		st.Znca = t
		return st.Save()
	}
	return znca.New(c, cfg, load, save)
}

func NewSession(st *Store, c *client.Client, cfg znca.Config) (*Session, error) {
	s := &Session{Store: st, Client: c}
	if cfg.ClientID == "" {
		return s, nil
	}

	z, err := NewZnca(c, st, cfg)
	if err != nil {
		return s, err
	}
	s.Znca = z
	return s, nil
}

func (s *Session) EnsureAccount() (*auth.AccountTokens, error) {
	st := s.Store
	if st.SessionToken == "" {
		return nil, ErrNotLoggedIn
	}
	if st.Account.Valid() {
		return st.Account, nil
	}

	t, err := auth.AccountToken(s.Client, st.SessionToken)
	if err != nil {
		var apiErr *client.APIError
		if errors.As(err, &apiErr) && strings.Contains(apiErr.Body, "invalid_grant") {
			st.SessionToken, st.Account, st.Coral, st.Profile, st.CoralUserID = "", nil, nil, nil, 0
			_ = st.Save()
			return nil, errors.New("session token rejected (invalid_grant) and deleted: run `nsonline login` again")
		}
		return nil, err
	}

	st.Account = t
	return t, st.Save()
}

func (s *Session) EnsureProfile(acct *auth.AccountTokens) (*auth.Profile, error) {
	st := s.Store
	if st.Profile != nil && st.Profile.ID != "" {
		return st.Profile, nil
	}

	u, err := auth.Me(s.Client, acct.AccessToken)
	if err != nil {
		return nil, err
	}

	st.Profile = &auth.Profile{ID: u.ID, Language: u.Language, Country: u.Country}
	return st.Profile, st.Save()
}

// EnsureCoral logs in only when the cached Coral token expired: Account/Login
// the first time, Account/GetToken afterwards.
func (s *Session) EnsureCoral() (*coral.Tokens, error) {
	st := s.Store
	if st.Coral.Valid() {
		return st.Coral, nil
	}
	if s.Znca == nil {
		return nil, errors.New("znca client not configured")
	}

	acct, err := s.EnsureAccount()
	if err != nil {
		return nil, err
	}
	profile, err := s.EnsureProfile(acct)
	if err != nil {
		return nil, err
	}
	if st.CoralUserID == 0 && st.Coral != nil {
		st.CoralUserID = st.Coral.UserID
	}

	tokens, err := coral.Login(s.Client, s.Znca, acct, profile, st.CoralUserID)
	if err != nil {
		var ce *coral.Error
		if errors.As(err, &ce) && st.CoralUserID != 0 && ce.Rejected() {
			// renewal refused: the next try does a full Account/Login
			st.Coral, st.CoralUserID = nil, 0
			_ = st.Save()
		}
		return nil, err
	}

	st.Coral, st.CoralUserID = tokens, tokens.UserID
	if tokens.FriendCode != "" {
		st.FriendCode = tokens.FriendCode
	}
	return tokens, st.Save()
}

// call drops a rejected Coral token but never retries (znca API terms): the next call logs in again.
func (s *Session) call(do func(token string) (json.RawMessage, error)) (json.RawMessage, error) {
	tokens, err := s.EnsureCoral()
	if err != nil {
		return nil, err
	}

	result, err := do(tokens.AccessToken)
	var ce *coral.Error
	if errors.As(err, &ce) && ce.Rejected() {
		s.Store.Coral = nil
		_ = s.Store.Save()
	}
	return result, err
}

func (s *Session) FriendsRaw() (json.RawMessage, error) {
	return s.call(func(token string) (json.RawMessage, error) { return coral.Friends(s.Client, s.Znca, token) })
}

func (s *Session) PlayLog(nsaID string) ([]providers.Game, error) {
	var games []providers.Game
	_, err := s.call(func(token string) (json.RawMessage, error) {
		var err error
		games, err = coral.PlayLog(s.Client, s.Znca, token, nsaID)
		return nil, err
	})
	return games, err
}

// EnsureFriendCode: the code comes with every Coral login; older caches get it once from User/ShowSelf.
func (s *Session) EnsureFriendCode() (string, error) {
	st := s.Store
	if st.FriendCode != "" {
		return st.FriendCode, nil
	}
	if _, err := s.EnsureCoral(); err != nil {
		return "", err
	}
	if st.FriendCode != "" {
		return st.FriendCode, nil
	}

	var code string
	_, err := s.call(func(token string) (json.RawMessage, error) {
		var err error
		code, err = coral.FriendCode(s.Client, s.Znca, token, st.CoralUserID)
		return nil, err
	})
	if err != nil {
		return "", err
	}

	st.FriendCode = code
	return code, st.Save()
}
