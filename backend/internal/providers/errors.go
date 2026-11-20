package providers

import (
	"context"
	"errors"
	"fmt"
	"time"
)

var ErrNotImplemented = errors.New("this console is not supported yet")

// MaxRetryAfter caps a server's Retry-After so a huge value cannot stop polling for years.
const MaxRetryAfter = time.Hour

func RetryAfter(err error) time.Duration {
	var w interface{ Wait() time.Duration }
	if errors.As(err, &w) {
		return min(w.Wait(), MaxRetryAfter)
	}
	return 0
}

func ErrorCode(err error) int {
	var c interface{ Code() int }
	if errors.As(err, &c) {
		return c.Code()
	}
	return 0
}

func IsFatal(err error) bool {
	var f interface{ Fatal() bool }
	return errors.As(err, &f) && f.Fatal()
}

func IsCanceled(err error) bool {
	return err != nil && errors.Is(err, context.Canceled)
}

type fatalError struct{ error }

func (fatalError) Fatal() bool     { return true }
func (e fatalError) Unwrap() error { return e.error }

// Fatal marks err as unrecoverable: the presence loop stops instead of retrying.
func Fatal(err error) error { return fatalError{err} }

// FindTarget is fatal only for a real list: an empty one is a Coral hiccup.
func FindTarget(friends []Friend, target string) (*Friend, error) {
	f, err := FindFriend(friends, target)
	if err == nil {
		return f, nil
	}
	if len(friends) == 0 {
		return nil, fmt.Errorf("empty friend list: %w", err)
	}
	return nil, Fatal(err)
}
