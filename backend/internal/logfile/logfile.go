// Package logfile is the size-rotating, redacted <data-dir>/logs/backend.log.
package logfile

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"sync"
)

type Rotator struct {
	path   string
	max    int64
	keep   int
	redact func([]byte) []byte

	mu   sync.Mutex
	f    *os.File
	size int64
}

func Open(path string, max int64, keep int, redact func([]byte) []byte) (*Rotator, error) {
	if max <= 0 || keep < 1 {
		return nil, fmt.Errorf("logfile: bad limits max=%d keep=%d", max, keep)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	r := &Rotator{path: path, max: max, keep: keep, redact: redact}
	if err := r.open(); err != nil {
		return nil, err
	}
	return r, nil
}

func (r *Rotator) open() error {
	f, err := os.OpenFile(r.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	fi, err := f.Stat()
	if err != nil {
		f.Close()
		return err
	}
	r.f, r.size = f, fi.Size()
	return nil
}

func (r *Rotator) Write(p []byte) (int, error) {
	n := len(p)
	if r.redact != nil {
		p = r.redact(p)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.f == nil {
		return 0, os.ErrClosed
	}
	if r.size > 0 && r.size+int64(len(p)) > r.max {
		if err := r.rotate(); err != nil {
			return 0, err
		}
	}
	if int64(len(p)) > r.max { // a single huge line: keep its start only
		p = append(bytes.Clone(p[:r.max-1]), '\n')
	}
	w, err := r.f.Write(p)
	r.size += int64(w)
	if err != nil {
		return 0, err
	}
	return n, nil
}

func (r *Rotator) rotate() error {
	r.f.Close()
	r.f = nil
	for i := r.keep - 1; i >= 1; i-- {
		src := r.path
		if i > 1 {
			src = fmt.Sprintf("%s.%d", r.path, i-1)
		}
		dst := fmt.Sprintf("%s.%d", r.path, i)
		os.Remove(dst) // Windows cannot rename over an existing file opened elsewhere
		_ = os.Rename(src, dst)
	}
	if r.keep == 1 {
		os.Remove(r.path)
	}
	return r.open()
}

func (r *Rotator) Close() error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.f == nil {
		return nil
	}
	err := r.f.Sync()
	if cerr := r.f.Close(); err == nil {
		err = cerr
	}
	r.f = nil
	return err
}

// Literals masks the given values. Values under 6 bytes are ignored: masking "1" everywhere would make logs unreadable.
func Literals(values ...string) func([]byte) []byte {
	var lits [][]byte
	for _, v := range values {
		if len(v) >= 6 {
			lits = append(lits, []byte(v))
		}
	}
	return func(b []byte) []byte {
		for _, l := range lits {
			if bytes.Contains(b, l) {
				b = bytes.ReplaceAll(b, l, []byte("…"))
			}
		}
		return b
	}
}

func Chain(fs ...func([]byte) []byte) func([]byte) []byte {
	return func(b []byte) []byte {
		for _, f := range fs {
			if f != nil {
				b = f(b)
			}
		}
		return b
	}
}

// Async drops lines when its queue is full: a parent that never drains our
// stderr pipe must not block the backend.
type Async struct {
	ch   chan []byte
	done chan struct{}
	once sync.Once
}

func NewAsync(w interface{ Write([]byte) (int, error) }, queue int) *Async {
	a := &Async{ch: make(chan []byte, queue), done: make(chan struct{})}
	go func() {
		defer close(a.done)
		for b := range a.ch {
			_, _ = w.Write(b)
		}
	}()
	return a
}

func (a *Async) Write(p []byte) (int, error) {
	defer func() { _ = recover() }() // write after Close: dropped
	select {
	case a.ch <- bytes.Clone(p):
	default: // full: drop
	}
	return len(p), nil
}

func (a *Async) Close() {
	a.once.Do(func() { close(a.ch) })
	<-a.done
}
