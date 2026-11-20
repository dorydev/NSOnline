package sidecar

import (
	"errors"
	"sync"
	"sync/atomic"
	"time"

	"nsonline/internal/discord"
	"nsonline/internal/presence"
	"nsonline/shared/i18n"
)

// sharedSink sends every Discord update over one IPC link, and lets the test
// activity hold it for a while before restoring what the loop wants shown.
type sharedSink struct {
	inner     presence.DiscordSink
	connected atomic.Bool // readable without waiting for an IPC exchange

	mu      sync.Mutex
	wantID  string
	want    *discord.Activity
	holding bool
	gen     int // invalidates older restore timers
	timer   *time.Timer
	closed  bool
}

func newSharedSink(inner presence.DiscordSink) *sharedSink { return &sharedSink{inner: inner} }

func (k *sharedSink) Set(clientID string, a *discord.Activity) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.closed {
		return nil
	}
	k.wantID, k.want = clientID, a
	if k.holding {
		return nil // sent by restore
	}
	return k.send(clientID, a)
}

func (k *sharedSink) send(clientID string, a *discord.Activity) error {
	err := k.inner.Set(clientID, a)
	k.connected.Store(k.inner.Connected())
	return err
}

func (k *sharedSink) Connected() bool { return k.connected.Load() }

func (k *sharedSink) ShowTest(clientID string, a *discord.Activity, d time.Duration) error {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.closed {
		return errors.New(i18n.T("api.error.shuttingDown"))
	}
	if err := k.send(clientID, a); err != nil {
		return err
	}
	k.holding = true
	k.gen++
	gen := k.gen
	if k.timer != nil {
		k.timer.Stop()
	}
	k.timer = time.AfterFunc(d, func() { k.restore(gen) })
	return nil
}

func (k *sharedSink) restore(gen int) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.closed || !k.holding || gen != k.gen {
		return
	}
	k.holding = false
	_ = k.send(k.wantID, k.want) // nil: clears the test activity
}

func (k *sharedSink) Probe(clientID string, probe func(string) error) error {
	if k.Connected() {
		return nil
	}
	k.mu.Lock() // no update in parallel with the probe connection
	defer k.mu.Unlock()
	return probe(clientID)
}

func (k *sharedSink) Close() {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.closed {
		return
	}
	k.closed = true
	if k.timer != nil {
		k.timer.Stop()
	}
	if k.inner.Connected() {
		_ = k.inner.Set("", nil)
	}
	if c, ok := k.inner.(interface{ Close() }); ok {
		c.Close()
	}
	k.connected.Store(false)
}
