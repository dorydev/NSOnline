package sidecar

import (
	"context"
	"errors"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
)

var errNotOwner = errors.New("upstream call outside the owner goroutine")

// netGate binds every upstream request to the context of whoever owns the
// network (the presence loop or one owner command): stopping the loop cancels
// its requests, and requests outside those windows fail.
type netGate struct {
	base http.RoundTripper
	ctx  atomic.Pointer[context.Context]
}

var closedCtx = func() context.Context {
	c, cancel := context.WithCancel(context.Background())
	cancel()
	return c
}()

func newNetGate(base http.RoundTripper) *netGate {
	g := &netGate{base: base}
	g.use(nil)
	return g
}

func (g *netGate) use(ctx context.Context) {
	if ctx == nil {
		ctx = closedCtx
	}
	g.ctx.Store(&ctx)
}

func (g *netGate) RoundTrip(r *http.Request) (*http.Response, error) {
	owner := *g.ctx.Load()
	if owner.Err() != nil {
		return nil, errNotOwner
	}
	// keep the request context (http.Client.Timeout lives there) and also end with the owner
	ctx, cancel := context.WithCancel(r.Context())
	stop := context.AfterFunc(owner, cancel)
	done := func() { stop(); cancel() }
	resp, err := g.base.RoundTrip(r.WithContext(ctx))
	if err != nil {
		done()
		if owner.Err() != nil {
			return nil, errors.Join(context.Canceled, err)
		}
		return nil, err
	}
	resp.Body = &doneBody{ReadCloser: resp.Body, done: done}
	return resp, nil
}

type doneBody struct {
	io.ReadCloser
	once sync.Once
	done func()
}

func (b *doneBody) Close() error {
	err := b.ReadCloser.Close()
	b.once.Do(b.done)
	return err
}
