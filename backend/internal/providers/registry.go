package providers

import (
	"fmt"
	"sync"
)

var (
	mu       sync.RWMutex
	registry []Provider
)

func Register(p Provider) {
	mu.Lock()
	defer mu.Unlock()

	for i, old := range registry {
		if old.Kind() == p.Kind() {
			registry[i] = p
			return
		}
	}
	registry = append(registry, p)
}

func Get(kind string) (Provider, error) {
	mu.RLock()
	defer mu.RUnlock()

	for _, p := range registry {
		if p.Kind() == kind {
			return p, nil
		}
	}
	return nil, fmt.Errorf("unsupported provider: %s", kind)
}

func All() []Provider {
	mu.RLock()
	defer mu.RUnlock()
	return append([]Provider(nil), registry...)
}

// PlatformOf falls back to the Nintendo Switch, the console of every Coral account.
func PlatformOf(id int) Platform {
	for _, p := range All() {
		for _, pl := range p.Platforms() {
			if pl.ID == id {
				return pl
			}
		}
	}
	return Platform{ID: id, Name: "Nintendo Switch", Asset: "switch"}
}
