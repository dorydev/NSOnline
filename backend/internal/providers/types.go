package providers

import (
	"fmt"
	"strings"
	"time"
)

const (
	StateOffline  = "OFFLINE"
	StateInactive = "INACTIVE"
	StateOnline   = "ONLINE"
	StatePlaying  = "PLAYING"
)

type Game struct {
	Name           string `json:"name"`
	ImageURI       string `json:"imageUri"`
	ShopURI        string `json:"shopUri"`
	TotalPlayTime  int    `json:"totalPlayTime"`
	FirstPlayedAt  int64  `json:"firstPlayedAt"`
	SysDescription string `json:"sysDescription"`
}

type Presence struct {
	State     string `json:"state"`
	Platform  int    `json:"platform"`
	UpdatedAt int64  `json:"updatedAt"`
	LogoutAt  int64  `json:"logoutAt"`
	Game      Game   `json:"game"`
}

func (p Presence) InGame() bool {
	return (p.State == StateOnline || p.State == StatePlaying) && p.Game.Name != ""
}

func (p Presence) ConsoleOn() bool {
	switch p.State {
	case StateInactive, StateOnline, StatePlaying:
		return true
	}
	return false
}

type Friend struct {
	ID       int64    `json:"id"`
	NsaID    string   `json:"nsaId"`
	Name     string   `json:"name"`
	ImageURI string   `json:"imageUri"`
	Presence Presence `json:"presence"`
}

// Observer is an account logged into nsonline.
type Observer struct {
	Connected  bool   `json:"connected"`
	Name       string `json:"name"`
	NsaID      string `json:"nsaId"`
	FriendCode string `json:"friendCode,omitempty"`
}

type TokenStatus struct {
	Session          bool       `json:"session"`
	AccountExpiresAt *time.Time `json:"accountExpiresAt"`
	CoralExpiresAt   *time.Time `json:"coralExpiresAt"`
	ZncaExpiresAt    *time.Time `json:"zncaExpiresAt"`
	ThirdPartyAck    bool       `json:"thirdPartyAck"`
}

type WebService struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Game     string `json:"game"`
	ImageURI string `json:"imageUri"`
	URL      string `json:"url"`
}

type Cookie struct {
	Name   string `json:"name"`
	Value  string `json:"value"`
	Domain string `json:"domain"`
}

// WebServiceOpen is what the app's WebView needs to open a game web service.
type WebServiceOpen struct {
	URL       string            `json:"url"`
	Token     string            `json:"token"`
	ExpiresAt time.Time         `json:"expiresAt"`
	UserAgent string            `json:"userAgent"`
	Cookies   []Cookie          `json:"cookies"`
	Headers   map[string]string `json:"headers"`
	Query     map[string]string `json:"query"`
}

func FindFriend(friends []Friend, query string) (*Friend, error) {
	for i := range friends {
		if friends[i].NsaID == query {
			return &friends[i], nil
		}
	}

	var matches []*Friend
	for i := range friends {
		if strings.EqualFold(friends[i].Name, query) {
			matches = append(matches, &friends[i])
		}
	}

	switch len(matches) {
	case 1:
		return matches[0], nil
	case 0:
		return nil, fmt.Errorf("no friend named or with nsaId %q (see `nsonline friends`)", query)
	default:
		return nil, fmt.Errorf("%d friends are named %q: use their nsaId instead (see `nsonline friends`)", len(matches), query)
	}
}
