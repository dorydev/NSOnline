package znca

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"time"
)

const clientAssertionType = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"

func newJTI() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return base64.RawURLEncoding.EncodeToString(b)
}

// clientAssertion is the HS256 JWT nxapi-auth accepts instead of a client secret.
func clientAssertion(clientID, aud string, key []byte, now time.Time) string {
	enc := func(v any) string {
		b, _ := json.Marshal(v)
		return base64.RawURLEncoding.EncodeToString(b)
	}

	head := enc(map[string]string{"alg": "HS256", "typ": "JWT"})
	body := enc(map[string]any{
		"typ": "client_assertion",
		"iss": clientID,
		"sub": clientID,
		"jti": newJTI(),
		"aud": aud,
		"iat": now.Unix(),
		"exp": now.Add(5 * time.Minute).Unix(),
	})

	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(head + "." + body))
	return head + "." + body + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}
