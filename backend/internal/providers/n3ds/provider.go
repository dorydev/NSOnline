// Package n3ds is a placeholder. Nintendo Network is closed since April 2024:
// the only source left is Pretendo's NEX friends server.
package n3ds

import "nsonline/internal/providers"

const Kind = "n3ds"

func init() { providers.Register(Provider{}) }

type Provider struct{}

func (Provider) Kind() string { return Kind }

// own platform ids, outside the values Coral uses
func (Provider) Platforms() []providers.Platform {
	return []providers.Platform{{ID: 1003, Name: "Nintendo 3DS", Asset: "3ds"}}
}

func (Provider) DiscordApp(int) string { return "" }

func (Provider) WebServices() []providers.WebService { return nil }

func (Provider) Open(string) (providers.Session, error) { return nil, providers.ErrNotImplemented }
