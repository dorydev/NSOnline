package coral

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"nsonline/internal/providers"
	"nsonline/internal/providers/nswitch/auth"
	"nsonline/internal/providers/nswitch/client"
	"nsonline/internal/providers/nswitch/znca"
)

// Coral statuses handled explicitly (full list in nxapi's coral-types.ts).
const (
	OK              = 0
	InvalidToken    = 9403
	TokenExpired    = 9404
	Forbidden       = 9405
	Unauthorised    = 9406
	NSANotLinked    = 9407
	UpgradeRequired = 9427
	RateLimited     = 9437
	MembershipReq   = 9450
)

type Error struct {
	Status        int
	Message       string
	CorrelationID string
}

func (e *Error) Error() string {
	hint := ""
	switch e.Status {
	case UpgradeRequired:
		hint = " (app version too old: set NSO_APP_VERSION, see znca /config)"
	case InvalidToken, TokenExpired:
		hint = " (Coral token rejected: it was dropped from the cache, run again)"
	case NSANotLinked:
		hint = " (no Switch linked to this Nintendo Account)"
	case RateLimited:
		hint = " (rate limited: wait before retrying)"
	}
	return fmt.Sprintf("coral status %d: %s%s", e.Status, e.Message, hint)
}

func (e *Error) Code() int   { return e.Status }
func (e *Error) Fatal() bool { return e.Status == UpgradeRequired }

func (e *Error) Rejected() bool { return e.Status == InvalidToken || e.Status == TokenExpired }

func userAgent() string { return "com.nintendo.znca/" + client.AppVersion() + "(Android/12)" }

type Tokens struct {
	AccessToken string    `json:"access_token"`
	ExpiresAt   time.Time `json:"expires_at"`
	UserID      int64     `json:"user_id"`
	NsaID       string    `json:"nsa_id"`
	Name        string    `json:"name"`
	FriendCode  string    `json:"friend_code,omitempty"`
}

func (t *Tokens) Valid() bool {
	return t != nil && t.AccessToken != "" && time.Until(t.ExpiresAt) > 5*time.Minute
}

type user struct {
	ID    int64  `json:"id"`
	NsaID string `json:"nsaId"`
	Name  string `json:"name"`
	Links struct {
		FriendCode struct {
			ID string `json:"id"`
		} `json:"friendCode"`
	} `json:"links"`
}

// Post sends an encrypted body and returns the decrypted "result".
func Post(c *client.Client, z *znca.Znca, path string, body []byte, bearer string) (json.RawMessage, error) {
	req, _ := http.NewRequest(http.MethodPost, client.CoralURL+path, bytes.NewReader(body))
	req.Header.Set("X-Platform", "Android")
	req.Header.Set("X-ProductVersion", client.AppVersion())
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("Accept", "application/octet-stream,application/json")
	req.Header.Set("Accept-Language", "en-GB")
	req.Header.Set("User-Agent", userAgent())
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}

	raw, err := c.Raw(req)
	if err != nil {
		return nil, fmt.Errorf("coral %s: %w", path, err)
	}

	// errors may come back as plain JSON, real answers are encrypted
	plain := raw
	if !json.Valid(raw) {
		if plain, err = z.DecryptResponse(raw); err != nil {
			return nil, err
		}
	}

	var wrap struct {
		Status        int             `json:"status"`
		Result        json.RawMessage `json:"result"`
		ErrorMessage  string          `json:"errorMessage"`
		CorrelationID string          `json:"correlationId"`
	}
	if err := json.Unmarshal(plain, &wrap); err != nil {
		return nil, fmt.Errorf("coral %s: decode: %w", path, err)
	}
	if wrap.Status != OK {
		return nil, &Error{Status: wrap.Status, Message: wrap.ErrorMessage, CorrelationID: wrap.CorrelationID}
	}
	return wrap.Result, nil
}

// Call sends {"parameter": parameter} with a valid Coral token.
func Call(c *client.Client, z *znca.Znca, coralToken, path string, parameter any) (json.RawMessage, error) {
	plain, err := json.Marshal(map[string]any{"parameter": parameter})
	if err != nil {
		return nil, err
	}
	return send(c, z, coralToken, path, plain)
}

func send(c *client.Client, z *znca.Znca, coralToken, path string, plain []byte) (json.RawMessage, error) {
	body, err := z.EncryptRequest(client.CoralURL+path, coralToken, plain)
	if err != nil {
		return nil, err
	}
	return Post(c, z, path, body, coralToken)
}

// field order follows the official app
type loginParameter struct {
	NaIDToken string `json:"naIdToken"`
	Language  string `json:"language"`
	Timestamp int64  `json:"timestamp"`
	RequestID string `json:"requestId"`
	F         string `json:"f"`
}

type tokenParameter struct {
	Timestamp int64  `json:"timestamp"`
	F         string `json:"f"`
	RequestID string `json:"requestId"`
	NaIDToken string `json:"naIdToken"`
}

// Login does Account/Login (coralUserID 0) or Account/GetToken: the znca API
// refuses to encrypt a second Login for the same Coral user.
func Login(c *client.Client, z *znca.Znca, acct *auth.AccountTokens, profile *auth.Profile, coralUserID int64) (*Tokens, error) {
	path := "/v4/Account/Login"
	var param any = &loginParameter{NaIDToken: acct.IDToken, Language: profile.Language}
	if coralUserID != 0 {
		path = "/v4/Account/GetToken"
		param = &tokenParameter{NaIDToken: acct.IDToken}
	}

	f, err := z.F(acct.IDToken, znca.HashCoral, profile.ID, coralUserID, &znca.EncryptTokenRequest{URL: client.CoralURL + path, Parameter: param})
	if err != nil {
		return nil, err
	}

	body := f.EncryptedRequest
	if body == nil {
		// older znca deployments: fill the fields ourselves and encrypt separately
		switch p := param.(type) {
		case *loginParameter:
			p.F, p.Timestamp, p.RequestID = f.F, f.Timestamp, f.RequestID
		case *tokenParameter:
			p.F, p.Timestamp, p.RequestID = f.F, f.Timestamp, f.RequestID
		}
		plain, _ := json.Marshal(map[string]any{"parameter": param})
		if body, err = z.EncryptRequest(client.CoralURL+path, "", plain); err != nil {
			return nil, err
		}
	}

	result, err := Post(c, z, path, body, "")
	if err != nil {
		return nil, err
	}

	var out struct {
		User       user `json:"user"`
		Credential struct {
			AccessToken string `json:"accessToken"`
			ExpiresIn   int    `json:"expiresIn"`
		} `json:"webApiServerCredential"`
	}
	if err := json.Unmarshal(result, &out); err != nil {
		return nil, err
	}
	if out.Credential.AccessToken == "" {
		return nil, fmt.Errorf("coral %s: no webApiServerCredential in response", path)
	}

	return &Tokens{
		AccessToken: out.Credential.AccessToken,
		ExpiresAt:   time.Now().Add(time.Duration(out.Credential.ExpiresIn) * time.Second),
		UserID:      out.User.ID,
		NsaID:       out.User.NsaID,
		Name:        out.User.Name,
		FriendCode:  out.User.Links.FriendCode.ID,
	}, nil
}

func ParseFriends(raw json.RawMessage) ([]providers.Friend, error) {
	var out struct {
		Friends []providers.Friend `json:"friends"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, err
	}
	return out.Friends, nil
}

func Friends(c *client.Client, z *znca.Znca, coralToken string) (json.RawMessage, error) {
	return Call(c, z, coralToken, "/v4/Friend/List", struct{}{})
}

func PlayLog(c *client.Client, z *znca.Znca, coralToken, nsaID string) ([]providers.Game, error) {
	raw, err := Call(c, z, coralToken, "/v4/User/PlayLog/Show", map[string]string{"nsaId": nsaID})
	if err != nil {
		return nil, err
	}

	var games []providers.Game
	if err := json.Unmarshal(raw, &games); err != nil {
		return nil, fmt.Errorf("play log: %w", err)
	}
	return games, nil
}

func FriendCode(c *client.Client, z *znca.Znca, coralToken string, coralUserID int64) (string, error) {
	raw, err := Call(c, z, coralToken, "/v4/User/ShowSelf", map[string]int64{"id": coralUserID})
	if err != nil {
		return "", err
	}

	var u user
	if err := json.Unmarshal(raw, &u); err != nil {
		return "", fmt.Errorf("show self: %w", err)
	}
	return u.Links.FriendCode.ID, nil
}

func uuid() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
