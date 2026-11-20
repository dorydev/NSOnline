package presence

import (
	"log"
	"sort"
	"sync"
	"time"

	"nsonline/internal/discord"
	"nsonline/internal/providers"
)

const (
	// MinInterval: each poll costs 1 Coral call + 2 znca calls, keep it gentle.
	MinInterval        = 15 * time.Second
	maxBackoff         = 10 * time.Minute
	clearAfterFailures = 4
	resendEvery        = 10 * time.Minute
)

type Sink interface {
	Set(clientID string, a *discord.Activity) error
}

// DiscordApps maps each console to its Discord app, whose name is the title Discord shows.
type DiscordApps struct {
	ByPlatform map[int]string
	Fallback   string
}

func AppsFromProviders(fallback string) DiscordApps {
	apps := DiscordApps{ByPlatform: map[int]string{}, Fallback: fallback}
	for _, p := range providers.All() {
		for _, pl := range p.Platforms() {
			if id := p.DiscordApp(pl.ID); id != "" {
				apps.ByPlatform[pl.ID] = id
			}
		}
	}
	return apps
}

func (a DiscordApps) platforms() []int {
	var ids []int
	for id := range a.ByPlatform {
		ids = append(ids, id)
	}
	sort.Sort(sort.Reverse(sort.IntSlice(ids)))
	return ids
}

// ForPlatform never returns "" when an app is configured: "" means "keep the
// current app", which would show the game under the wrong title.
func (a DiscordApps) ForPlatform(platform int) string {
	if id := a.ByPlatform[platform]; id != "" {
		return id
	}
	if a.Fallback != "" {
		return a.Fallback
	}
	for _, p := range a.platforms() {
		if id := a.ByPlatform[p]; id != "" {
			return id
		}
	}
	return ""
}

func (a DiscordApps) Configured() bool { return a.ForPlatform(0) != "" }

// Backoff doubles the delay per failure, up to maxBackoff, and never waits less than Retry-After.
func Backoff(base time.Duration, failures int, retryAfter time.Duration) time.Duration {
	d := base
	for i := 1; i < failures && d < maxBackoff; i++ {
		d *= 2
	}
	d = min(d, maxBackoff)
	return max(d, min(retryAfter, providers.MaxRetryAfter))
}

func AtLeast(d, floor time.Duration) time.Duration {
	if d < floor {
		log.Printf("interval raised from %s to %s", d, floor)
		return floor
	}
	return d
}

func Fatal(err error) error { return providers.Fatal(err) }

func IsFatal(err error) bool { return providers.IsFatal(err) }

func FindTarget(friends []providers.Friend, target string) (*providers.Friend, error) {
	return providers.FindTarget(friends, target)
}

func logPresence(name string, p providers.Presence, a *discord.Activity) {
	if name == "" {
		return
	}
	if a == nil {
		log.Printf("%s: %s, presence cleared", name, p.State)
		return
	}
	log.Printf("%s on %s: %s — %s", name, providers.PlatformOf(p.Platform).Name, a.Details, a.State)
}

// Watcher polls one account's presence and mirrors it to Discord.
type Watcher struct {
	Fetch          func() (providers.Presence, string, error)
	Sink           Sink
	Apps           DiscordApps
	Interval, Idle time.Duration
	Now            func() time.Time

	ShowIdle   func() bool
	Player     func() Player
	Mapper     *Mapper
	FirstDelay time.Duration
	OnSync     func(p providers.Presence, activity *discord.Activity, clientID string)

	mapper   Mapper
	shown    string // "-" = unknown
	lastSent time.Time
	failures int

	last     *providers.Presence
	lastName string
	once     sync.Once
	resync   chan struct{}
}

func (w *Watcher) init() { w.once.Do(func() { w.resync = make(chan struct{}, 1) }) }

// Resync sends the last known presence again without polling. Safe from any goroutine.
func (w *Watcher) Resync() {
	w.init()
	select {
	case w.resync <- struct{}{}:
	default:
	}
}

func (w *Watcher) Run(stop <-chan struct{}) error {
	w.init()
	w.shown = "-"

	timer := time.NewTimer(max(w.FirstDelay, 0))
	defer timer.Stop()

	for {
		select {
		case <-stop:
			return nil
		case <-w.resync:
			if w.last != nil {
				w.shown = "-"
				_ = w.sync(*w.last, w.lastName)
			}
		case <-timer.C:
			next, err := w.tick()
			if err != nil {
				return err
			}
			timer.Reset(next)
		}
	}
}

func (w *Watcher) tick() (time.Duration, error) {
	p, name, err := w.Fetch()
	if err != nil {
		if providers.IsFatal(err) {
			return 0, err
		}

		w.failures++
		next := Backoff(w.Interval, w.failures, providers.RetryAfter(err))
		log.Printf("presence: %v (retry in %s)", err, next)

		if w.failures == clearAfterFailures && w.last != nil && w.last.ConsoleOn() {
			// Nintendo unreachable for a while: stop showing a game that may have ended
			w.last = &providers.Presence{}
			_ = w.sync(*w.last, w.lastName)
		}
		return next, nil
	}

	w.failures = 0
	w.last, w.lastName = &p, name

	if err := w.sync(p, name); err != nil {
		log.Printf("discord: %v (retry in %s)", err, w.Interval)
		return w.Interval, nil
	}
	if p.InGame() {
		return w.Interval, nil
	}
	return w.Idle, nil
}

func (w *Watcher) sync(p providers.Presence, name string) error {
	m := w.Mapper
	if m == nil {
		m = &w.mapper
	}
	m.ShowIdle = w.ShowIdle != nil && w.ShowIdle()
	m.Player = Player{}
	if w.Player != nil {
		m.Player = w.Player()
	}

	activity := m.Map(p, w.Now())
	clientID := ""
	if activity != nil {
		clientID = w.Apps.ForPlatform(p.Platform)
	}

	key := clientID + "|" + activityKey(activity)
	stale := activity != nil && w.Now().Sub(w.lastSent) >= resendEvery
	if key == w.shown && !stale {
		return nil
	}

	if err := w.Sink.Set(clientID, activity); err != nil {
		w.shown = "-"
		return err
	}
	if key != w.shown {
		logPresence(name, p, activity)
	}
	w.shown, w.lastSent = key, w.Now()

	if w.OnSync != nil {
		w.OnSync(p, activity, clientID)
	}
	return nil
}

// Platforms lists the per-console app ids, highest platform first.
func (a DiscordApps) Platforms() []string {
	var ids []string
	for _, p := range a.platforms() {
		ids = append(ids, a.ByPlatform[p])
	}
	return ids
}
