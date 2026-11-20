package api

import (
	"sync"
	"time"
)

// bucket is a token bucket: rate tokens per second, at most burst stored.
type bucket struct {
	mu     sync.Mutex
	rate   float64
	burst  float64
	tokens float64
	last   time.Time
	now    func() time.Time
}

func newBucket(rate float64, burst int, now func() time.Time) *bucket {
	return &bucket{rate: rate, burst: float64(burst), tokens: float64(burst), now: now}
}

// take consumes one token, or reports how long until one is available.
func (b *bucket) take() (bool, time.Duration) {
	b.mu.Lock()
	defer b.mu.Unlock()
	now := b.now()
	if !b.last.IsZero() {
		if dt := now.Sub(b.last).Seconds(); dt > 0 {
			b.tokens = min(b.burst, b.tokens+dt*b.rate)
		}
	}
	b.last = now
	if b.tokens >= 1 {
		b.tokens--
		return true, 0
	}
	return false, time.Duration((1 - b.tokens) / b.rate * float64(time.Second))
}
