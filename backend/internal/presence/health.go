package presence

import (
	"sync"
	"time"

	"nsonline/internal/providers"
)

const (
	CoralOK       = "ok"
	CoralDegraded = "degraded"
	CoralDown     = "down"
	CoralUnknown  = "unknown"
)

const slowPoll = 5 * time.Second

// CoralStatus is the health of the poll path, served in /api/status.
type CoralStatus struct {
	State               string     `json:"state"`
	LatencyMs           int64      `json:"latencyMs"`
	LastSuccess         *time.Time `json:"lastSuccess"`
	LastError           string     `json:"lastError"`
	LastErrorCode       int        `json:"lastErrorCode"`
	ConsecutiveFailures int        `json:"consecutiveFailures"`
	RetryAfterSeconds   int        `json:"retryAfterSeconds"`
}

func shorten(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && s[n]&0xc0 == 0x80 {
		n--
	}
	return s[:n] + "…"
}

// CoralTracker records poll outcomes. It outlives a Service so restarts keep the history.
type CoralTracker struct {
	mu sync.Mutex
	coralState
}

type coralState struct {
	attempted   bool
	lastAttempt time.Time
	latency     time.Duration
	lastSuccess *time.Time
	lastErr     string
	code        int
	failures    int
	retryAfter  time.Duration
	fatal       bool
}

// Record ignores cancelled polls: the loop being stopped is not a failure.
func (t *CoralTracker) Record(at time.Time, latency time.Duration, err error) {
	if providers.IsCanceled(err) {
		return
	}

	t.mu.Lock()
	defer t.mu.Unlock()

	t.attempted, t.lastAttempt, t.latency = true, at, latency
	if err == nil {
		ok := at
		t.lastSuccess, t.failures, t.retryAfter, t.fatal = &ok, 0, 0, false
		return
	}

	t.failures++
	t.lastErr = shorten(err.Error(), 300)
	t.code = providers.ErrorCode(err)
	t.retryAfter = providers.RetryAfter(err)
	t.fatal = providers.IsFatal(err)
}

func (t *CoralTracker) Reset() {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.coralState = coralState{}
}

func (t *CoralTracker) LastAttempt() time.Time {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.lastAttempt
}

// Status: unknown before any poll or when stale (3×every), down after 3
// failures or a fatal error, degraded after 1–2 failures, a Retry-After or a slow poll.
func (t *CoralTracker) Status(now time.Time, every time.Duration) CoralStatus {
	t.mu.Lock()
	defer t.mu.Unlock()

	st := CoralStatus{
		LatencyMs:           t.latency.Milliseconds(),
		LastError:           t.lastErr,
		LastErrorCode:       t.code,
		ConsecutiveFailures: t.failures,
		RetryAfterSeconds:   int(t.retryAfter / time.Second),
	}
	if t.lastSuccess != nil {
		ls := *t.lastSuccess
		st.LastSuccess = &ls
	}

	switch {
	case !t.attempted:
		st.State = CoralUnknown
	case t.fatal || t.failures >= 3:
		st.State = CoralDown
	case t.failures > 0 || t.retryAfter > 0 || t.latency > slowPoll:
		st.State = CoralDegraded
	case every > 0 && now.Sub(*t.lastSuccess) > 3*every:
		st.State = CoralUnknown
	default:
		st.State = CoralOK
	}
	return st
}
