package znca

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"nsonline/internal/providers/nswitch/client"
)

const (
	DefaultURL     = "https://nxapi-znca-api.fancy.org.uk/api/znca/"
	DefaultAuthURL = "https://nxapi-auth.fancy.org.uk/api/oauth/token"
	DefaultIssuer  = "https://nxapi-auth.fancy.org.uk"
	Scope          = "ca:gf ca:er ca:dr"
	ToolVersion    = "0.1"

	// fixed compatibility value expected by nxapi-znca-api
	clientVersion = "d8fAZDPzwimzQ7c6"
)

const (
	HashCoral      = 1
	HashWebService = 2
)

type Token struct {
	AccessToken  string    `json:"access_token"`
	RefreshToken string    `json:"refresh_token,omitempty"`
	ExpiresAt    time.Time `json:"expires_at"`
	// NaID: the znca API binds a token to the Nintendo Account it was first used for.
	NaID string `json:"na_id,omitempty"`
}

func (t *Token) Valid() bool {
	return t != nil && t.AccessToken != "" && time.Until(t.ExpiresAt) > time.Minute
}

type Config struct {
	BaseURL, TokenURL, Issuer string
	ClientID                  string
	ClientSecret              string
	SharedSecret              string
	Contact                   string
}

// Znca talks to nxapi-auth and nxapi-znca-api. Load and Save give access to the
// cached nxapi-auth token (kept in nso-auth.json).
type Znca struct {
	*client.Client
	BaseURL      string
	TokenURL     string
	ClientID     string
	ClientSecret string
	SharedSecret string
	Issuer       string
	Contact      string

	Load func() *Token
	Save func(*Token) error

	naID string
}

func or(v, def string) string {
	if v != "" {
		return v
	}
	return def
}

func secureURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	if u.Scheme == "https" {
		return true
	}

	host := u.Hostname()
	ip := net.ParseIP(host)
	return u.Scheme == "http" && (host == "localhost" || (ip != nil && ip.IsLoopback()))
}

func New(c *client.Client, cfg Config, load func() *Token, save func(*Token) error) (*Znca, error) {
	if cfg.ClientID == "" {
		return nil, errors.New("NXAPI_ZNCA_API_CLIENT_ID is not set: register a client at https://nxapi-auth.fancy.org.uk and add it to .env")
	}
	for _, u := range []string{cfg.BaseURL, cfg.TokenURL} {
		if u != "" && !secureURL(u) {
			return nil, fmt.Errorf("znca: %s must use https (plain http only to localhost)", u)
		}
	}

	z := &Znca{
		Client:       c,
		BaseURL:      or(cfg.BaseURL, DefaultURL),
		TokenURL:     or(cfg.TokenURL, DefaultAuthURL),
		Issuer:       or(cfg.Issuer, DefaultIssuer),
		ClientID:     cfg.ClientID,
		ClientSecret: cfg.ClientSecret,
		SharedSecret: cfg.SharedSecret,
		Contact:      cfg.Contact,
		Load:         load,
		Save:         save,
	}
	if !strings.HasSuffix(z.BaseURL, "/") {
		z.BaseURL += "/"
	}
	return z, nil
}

func (z *Znca) userAgent() string {
	ua := "nsonline/" + ToolVersion
	if z.Contact != "" {
		ua += " (+" + z.Contact + ")"
	}
	return ua
}

func (z *Znca) cached() *Token {
	if z.Load == nil {
		return nil
	}
	return z.Load()
}

func (z *Znca) store(t *Token) error {
	if z.Save == nil {
		return nil
	}
	return z.Save(t)
}

func (z *Znca) EnsureToken() error {
	_, err := z.token()
	return err
}

func (z *Znca) token() (string, error) {
	old := z.cached()
	if old.Valid() {
		return old.AccessToken, nil
	}

	prevNaID, refresh := "", ""
	if old != nil {
		prevNaID, refresh = old.NaID, old.RefreshToken
	}

	form := url.Values{"client_id": {z.ClientID}, "scope": {Scope}}
	if refresh != "" {
		form.Set("grant_type", "refresh_token")
		form.Set("refresh_token", refresh)
	} else {
		form.Set("grant_type", "client_credentials")
	}
	switch {
	case z.ClientSecret != "":
		form.Set("client_secret", z.ClientSecret)
	case z.SharedSecret != "":
		form.Set("client_assertion_type", clientAssertionType)
		form.Set("client_assertion", clientAssertion(z.ClientID, z.Issuer, []byte(z.SharedSecret), time.Now()))
	}

	req, _ := http.NewRequest(http.MethodPost, z.TokenURL, strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", z.userAgent())

	var out struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int    `json:"expires_in"`
	}
	if err := z.Do(req, &out); err != nil {
		var apiErr *client.APIError
		if errors.As(err, &apiErr) && strings.Contains(apiErr.Body, "invalid_grant") && refresh != "" {
			// dead refresh token: start over with the client credentials, like nxapi
			_ = z.store(nil)
			return z.token()
		}
		return "", fmt.Errorf("nxapi-auth: %w", err)
	}

	t := &Token{
		AccessToken:  out.AccessToken,
		RefreshToken: out.RefreshToken,
		ExpiresAt:    time.Now().Add(time.Duration(out.ExpiresIn) * time.Second),
		NaID:         or(z.naID, prevNaID),
	}
	return out.AccessToken, z.store(t)
}

func (z *Znca) call(path string, body any, accept string) ([]byte, error) {
	tok, err := z.token()
	if err != nil {
		return nil, err
	}

	b, _ := json.Marshal(body)
	req, _ := http.NewRequest(http.MethodPost, z.BaseURL+path, bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", accept)
	req.Header.Set("User-Agent", z.userAgent())
	req.Header.Set("X-znca-Platform", "Android")
	req.Header.Set("X-znca-Version", client.AppVersion())
	req.Header.Set("X-znca-Client-Version", clientVersion)
	req.Header.Set("Authorization", "Bearer "+tok)

	out, err := z.Raw(req)
	if err != nil {
		var apiErr *client.APIError
		if errors.As(err, &apiErr) && strings.Contains(apiErr.Body, "invalid_token") {
			_ = z.store(nil)
		}
		return nil, fmt.Errorf("znca %s: %w", path, err)
	}

	// the API may answer 200 with {"error": ...}
	if accept == "application/json" {
		var e struct {
			Error   string `json:"error"`
			Message string `json:"error_message"`
		}
		if json.Unmarshal(out, &e) == nil && e.Error != "" {
			return nil, fmt.Errorf("znca %s: %s: %s", path, e.Error, e.Message)
		}
	}
	return out, nil
}

type FResult struct {
	F                string `json:"f"`
	RequestID        string `json:"request_id"`
	Timestamp        int64  `json:"timestamp"`
	EncryptedRequest []byte `json:"-"`
}

// EncryptTokenRequest asks /f to fill f, timestamp and requestId and encrypt the Coral body.
type EncryptTokenRequest struct {
	URL       string `json:"url"`
	Parameter any    `json:"parameter"`
}

// F generates an f token. HashCoral: token is the NA id token. HashWebService: the Coral token.
func (z *Znca) F(token string, hashMethod int, naID string, coralUserID int64, encrypt *EncryptTokenRequest) (*FResult, error) {
	z.naID = naID
	if t := z.cached(); t != nil && t.NaID != naID {
		_ = z.store(nil)
	}

	body := map[string]any{
		"hash_method": fmt.Sprint(hashMethod),
		"token":       token,
		"na_id":       naID,
	}
	if coralUserID != 0 {
		body["coral_user_id"] = fmt.Sprint(coralUserID)
	}
	if encrypt != nil {
		body["encrypt_token_request"] = encrypt
	}

	raw, err := z.call("f", body, "application/json")
	if err != nil {
		return nil, err
	}

	var out struct {
		FResult
		Encrypted string `json:"encrypted_token_request"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}

	res := out.FResult
	if out.Encrypted != "" {
		if res.EncryptedRequest, err = decodeBase64(out.Encrypted); err != nil {
			return nil, fmt.Errorf("znca f: bad encrypted_token_request: %w", err)
		}
	}
	return &res, nil
}

func (z *Znca) EncryptRequest(coralURL, coralToken string, data []byte) ([]byte, error) {
	var tok any
	if coralToken != "" {
		tok = coralToken
	}

	raw, err := z.call("encrypt-request", map[string]any{"url": coralURL, "token": tok, "data": string(data)}, "application/json")
	if err != nil {
		return nil, err
	}

	var out struct {
		Data string `json:"data"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	return decodeBase64(out.Data)
}

func (z *Znca) DecryptResponse(data []byte) ([]byte, error) {
	return z.call("decrypt-response", map[string]any{"data": base64.StdEncoding.EncodeToString(data)}, "text/plain")
}

// decodeBase64 takes standard and URL-safe base64, padded or not: the docs say
// base64url, the live API answers standard base64.
func decodeBase64(s string) ([]byte, error) {
	s = strings.TrimRight(strings.NewReplacer("-", "+", "_", "/").Replace(s), "=")
	return base64.RawStdEncoding.DecodeString(s)
}
