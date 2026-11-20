// Package secrets reads the configuration embedded at build time (secrets_gen.go).
// This is obfuscation, not security (see package seal). A non-empty environment
// variable always overrides the embedded value.
package secrets

//go:generate go run ./gen -env ../../../.env -out secrets_gen.go

import (
	"log"
	"os"
	"strings"
	"sync"

	"nsonline/internal/secrets/seal"
)

var Keys = []string{
	"DISCORD_CLIENT_ID",
	"DISCORD_CLIENT_ID_SWITCH",
	"DISCORD_CLIENT_ID_SWITCH2",
	"NXAPI_ZNCA_API_CLIENT_ID",
	"NXAPI_ZNCA_API_CLIENT_SECRET",
	"NXAPI_ZNCA_API_SHARED_SECRET",
	"NSONLINE_CONTACT",
	"NSO_APP_VERSION",
}

var (
	sealed    []byte
	keyShares [][]byte
)

var (
	once     sync.Once
	embedded map[string]string
)

func Get(key string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return Embedded(key)
}

func Embedded(key string) string {
	once.Do(func() {
		m, err := seal.Open(sealed, seal.Join(keyShares))
		if err != nil {
			log.Printf("embedded configuration unreadable (%v): rebuild with `make build`", err)
			m = map[string]string{}
		}
		embedded = m
	})
	return embedded[key]
}

func HasEmbedded() bool { return len(sealed) > 0 }
