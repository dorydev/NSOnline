package auth

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"nsonline/internal/providers/nswitch/client"
)

// ClientID is the public client id of the Nintendo Switch Online app.
const (
	ClientID    = "71b963c1b7b6d119"
	RedirectURI = "npf" + ClientID + "://auth"
)

func userAgent() string { return "OnlineLounge/" + client.AppVersion() + " NASDKAPI Android" }

func newRequest(method, url string, body []byte, contentType string) *http.Request {
	req, _ := http.NewRequest(method, url, bytes.NewReader(body))
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", userAgent())
	return req
}

type LoginRequest struct {
	URL   string
	State string
	PKCE  PKCE
}

func NewLoginRequest() (*LoginRequest, error) {
	pkce, err := NewPKCE()
	if err != nil {
		return nil, err
	}
	state, err := randomString(36)
	if err != nil {
		return nil, err
	}

	q := url.Values{
		"client_id":                           {ClientID},
		"redirect_uri":                        {RedirectURI},
		"response_type":                       {"session_token_code"},
		"scope":                               {"openid user user.birthday user.mii user.screenName"},
		"session_token_code_challenge":        {pkce.Challenge},
		"session_token_code_challenge_method": {"S256"},
		"state":                               {state},
		"theme":                               {"login_form"},
	}
	return &LoginRequest{
		URL:   client.AccountsURL + "/connect/1.0.0/authorize?" + q.Encode(),
		State: state,
		PKCE:  pkce,
	}, nil
}

// ParseRedirect reads session_token_code from the npf…://auth#… link (it is in the fragment).
func (l *LoginRequest) ParseRedirect(link string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(link))
	if err != nil {
		return "", err
	}
	if !strings.HasPrefix(u.Scheme, "npf") {
		return "", fmt.Errorf("expected an npf…://auth link, got scheme %q", u.Scheme)
	}

	params, err := url.ParseQuery(u.Fragment)
	if err != nil {
		return "", err
	}
	if e := params.Get("error"); e != "" {
		return "", fmt.Errorf("login error: %s (%s)", e, params.Get("error_description"))
	}
	if params.Get("state") != l.State {
		return "", errors.New("state mismatch: this link is not from the login you just started")
	}

	code := params.Get("session_token_code")
	if code == "" {
		return "", errors.New("no session_token_code in link")
	}
	return code, nil
}

func ExchangeSessionToken(c *client.Client, l *LoginRequest, code string) (string, error) {
	form := url.Values{
		"client_id":                   {ClientID},
		"session_token_code":          {code},
		"session_token_code_verifier": {l.PKCE.Verifier},
	}
	req := newRequest(http.MethodPost, client.AccountsURL+"/connect/1.0.0/api/session_token", []byte(form.Encode()), "application/x-www-form-urlencoded")

	var out struct {
		SessionToken string `json:"session_token"`
	}
	if err := c.Do(req, &out); err != nil {
		return "", fmt.Errorf("session_token: %w", err)
	}
	if out.SessionToken == "" {
		return "", errors.New("session_token: empty token in response")
	}
	return out.SessionToken, nil
}

type AccountTokens struct {
	IDToken     string    `json:"id_token"`
	AccessToken string    `json:"access_token"`
	ExpiresAt   time.Time `json:"expires_at"`
}

func (t *AccountTokens) Valid() bool {
	return t != nil && t.AccessToken != "" && time.Until(t.ExpiresAt) > time.Minute
}

func AccountToken(c *client.Client, sessionToken string) (*AccountTokens, error) {
	body, _ := json.Marshal(map[string]string{
		"client_id":     ClientID,
		"session_token": sessionToken,
		"grant_type":    "urn:ietf:params:oauth:grant-type:jwt-bearer-session-token",
	})
	req := newRequest(http.MethodPost, client.AccountsURL+"/connect/1.0.0/api/token", body, "application/json")

	var out struct {
		IDToken     string `json:"id_token"`
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := c.Do(req, &out); err != nil {
		return nil, fmt.Errorf("token: %w", err)
	}

	return &AccountTokens{
		IDToken:     out.IDToken,
		AccessToken: out.AccessToken,
		ExpiresAt:   time.Now().Add(time.Duration(out.ExpiresIn) * time.Second),
	}, nil
}

type User struct {
	ID         string          `json:"id"`
	Nickname   string          `json:"nickname"`
	ScreenName string          `json:"screenName"`
	Country    string          `json:"country"`
	Language   string          `json:"language"`
	Birthday   string          `json:"birthday"`
	Raw        json.RawMessage `json:"-"`
}

func Me(c *client.Client, accessToken string) (*User, error) {
	req := newRequest(http.MethodGet, client.APIURL+"/2.0.0/users/me", nil, "")
	req.Header.Set("Authorization", "Bearer "+accessToken)

	var raw json.RawMessage
	if err := c.Do(req, &raw); err != nil {
		return nil, fmt.Errorf("users/me: %w", err)
	}

	var u User
	if err := json.Unmarshal(raw, &u); err != nil {
		return nil, err
	}
	u.Raw = raw
	return &u, nil
}

// Profile is the part of /users/me reused by every Coral login.
type Profile struct {
	ID       string `json:"id"`
	Language string `json:"language"`
	Country  string `json:"country,omitempty"`
}
