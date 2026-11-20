package nswitch

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"

	"nsonline/internal/providers"
	"nsonline/internal/providers/nswitch/auth"
	"nsonline/internal/providers/nswitch/coral"
	"nsonline/internal/providers/nswitch/znca"
)

// Store is nso-auth.json. It gives access to the account: keep it out of git.
// The JSON names are the file format of every existing install: never rename them.
type Store struct {
	SessionToken     string              `json:"session_token"`
	Account          *auth.AccountTokens `json:"account,omitempty"`
	Coral            *coral.Tokens       `json:"coral,omitempty"`
	CoralUserID      int64               `json:"coral_user_id,omitempty"`
	FriendCode       string              `json:"friend_code,omitempty"`
	Znca             *znca.Token         `json:"znca,omitempty"`
	Profile          *auth.Profile       `json:"profile,omitempty"`
	ThirdPartyAck    bool                `json:"third_party_ack,omitempty"`
	ThirdPartyAckURL string              `json:"third_party_ack_url,omitempty"`

	path string
}

func LoadStore(path string) (*Store, error) {
	s := &Store{path: path}

	b, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}

	if err := json.Unmarshal(b, s); err != nil {
		return nil, err
	}
	return s, nil
}

func (s *Store) Path() string { return s.path }

func (s *Store) Save() error {
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}

	tmp, err := os.CreateTemp(filepath.Dir(s.path), ".nso-auth-*.tmp")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())

	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), s.path)
}

// ResetSession drops every token derived from the previous session (znca tokens are bound to one user).
func (s *Store) ResetSession(sessionToken string) error {
	s.SessionToken = sessionToken
	s.Account, s.Coral, s.Znca, s.Profile, s.CoralUserID = nil, nil, nil, nil, 0
	s.FriendCode = ""
	return s.Save()
}

// AckedFor: a consent given before URLs were recorded covers the default public service only.
func (s *Store) AckedFor(url string) bool {
	if s.ThirdPartyAckURL != "" {
		return s.ThirdPartyAckURL == url
	}
	return s.ThirdPartyAck && url == znca.DefaultURL
}

func (s *Store) AckThirdParty(url string) {
	s.ThirdPartyAck, s.ThirdPartyAckURL = true, url
}

func (s *Store) Tokens() (providers.TokenStatus, providers.Observer) {
	ts := providers.TokenStatus{Session: s.SessionToken != "", ThirdPartyAck: s.ThirdPartyAck}
	if s.Account != nil {
		t := s.Account.ExpiresAt
		ts.AccountExpiresAt = &t
	}
	if s.Coral != nil {
		t := s.Coral.ExpiresAt
		ts.CoralExpiresAt = &t
	}
	if s.Znca != nil {
		t := s.Znca.ExpiresAt
		ts.ZncaExpiresAt = &t
	}
	return ts, s.Observer()
}

func (s *Store) Observer() providers.Observer {
	obs := providers.Observer{Connected: s.SessionToken != "", FriendCode: s.FriendCode}
	if s.Coral != nil {
		obs.Name, obs.NsaID = s.Coral.Name, s.Coral.NsaID
	}
	return obs
}

// SamePath: two sessions must never share one token file.
func SamePath(a, b string) bool {
	if fa, err := os.Stat(a); err == nil {
		if fb, err := os.Stat(b); err == nil {
			return os.SameFile(fa, fb)
		}
	}

	absA, errA := filepath.Abs(a)
	absB, errB := filepath.Abs(b)
	return errA == nil && errB == nil && absA == absB
}
