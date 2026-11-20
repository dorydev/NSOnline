// Package wiiu is a placeholder. Nintendo Network is closed since April 2024:
// the only source left is Pretendo's NEX friends server.
package wiiu

import "nsonline/internal/providers"

const Kind = "wiiu"

func init() { providers.Register(Provider{}) }

type Provider struct{}

func (Provider) Kind() string { return Kind }

// own platform ids, outside the values Coral uses
func (Provider) Platforms() []providers.Platform {
	return []providers.Platform{{ID: 1004, Name: "Wii U", Asset: "wiiu"}}
}

func (Provider) DiscordApp(int) string { return "" }

func (Provider) WebServices() []providers.WebService { return nil }

func (Provider) Open(string) (providers.Session, error) { return nil, providers.ErrNotImplemented }
