// Package api is the local HTTP API of the desktop app (loopback only).
// The Host check blocks DNS rebinding, and X-NSO-RPC is a custom header a
// browser only sends after a CORS preflight this server never grants.
package api

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"nsonline/internal/presence"
	"nsonline/internal/version"
	"nsonline/shared/i18n"
)

const ClientHeader = "X-NSO-RPC"

const MaxBody = 64 << 10

type Backend interface {
	Status() presence.Status
	Friends() presence.Snapshot
	Config() presence.Config
	SetEnabled(bool)
}

// Options: Token, when set, is required as a Bearer token. Rate and Burst
// default to 50 req/s, burst 100.
type Options struct {
	Port  string
	Token string
	Rate  float64
	Burst int
	Now   func() time.Time
}

func Handler(b Backend, port string) http.Handler { return NewHandler(b, Options{Port: port}) }

// NewHandler serves the app routes only when b also implements AppBackend.
func NewHandler(b Backend, o Options) http.Handler {
	if o.Rate <= 0 {
		o.Rate = 50
	}
	if o.Burst <= 0 {
		o.Burst = 100
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]any{"ok": true, "version": version.Version})
	})
	mux.HandleFunc("GET /api/status", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, b.Status()) })
	mux.HandleFunc("GET /api/friends", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, b.Friends()) })
	mux.HandleFunc("GET /api/config", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, b.Config()) })
	mux.HandleFunc("PUT /api/presence", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Enabled *bool `json:"enabled"`
		}
		if e := decode(w, r, &body, 1<<10); e != nil {
			e.Message = i18n.T("api.error.expectedEnabled")
			writeError(w, e)
			return
		}
		if body.Enabled == nil {
			writeError(w, &Error{Status: http.StatusBadRequest, Code: "missing_field", Field: "enabled", Message: i18n.T("api.error.expectedEnabled")})
			return
		}
		b.SetEnabled(*body.Enabled)
		writeJSON(w, b.Status())
	})
	if ab, ok := b.(AppBackend); ok {
		appRoutes(mux, ab)
	}
	if wb, ok := b.(WebServicesBackend); ok && o.Token != "" {
		webServiceRoutes(mux, wb)
	}
	limiter := newBucket(o.Rate, o.Burst, o.Now)
	return guard(routed(mux), o, limiter)
}

func NewServer(addr string, h http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    16 << 10,
	}
}

func guard(next http.Handler, o Options, limiter *bucket) http.Handler {
	allowed := map[string]bool{
		net.JoinHostPort("127.0.0.1", o.Port): true,
		net.JoinHostPort("localhost", o.Port): true,
		net.JoinHostPort("::1", o.Port):       true, // "[::1]:port"
	}
	var want [32]byte
	if o.Token != "" {
		want = sha256.Sum256([]byte(o.Token))
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !allowed[r.Host] {
			writeError(w, &Error{Status: http.StatusForbidden, Code: "bad_host", Message: i18n.T("api.error.badHost")})
			return
		}
		if r.Header.Get(ClientHeader) != "1" {
			writeError(w, &Error{Status: http.StatusForbidden, Code: "missing_client_header", Message: i18n.T("api.error.missingHeader", i18n.Args{"header": ClientHeader})})
			return
		}
		if o.Token != "" {
			// hash both sides: constant time whatever the length of the guess
			got := sha256.Sum256([]byte(bearer(r.Header.Get("Authorization"))))
			if subtle.ConstantTimeCompare(got[:], want[:]) != 1 {
				w.Header().Set("WWW-Authenticate", "Bearer")
				writeError(w, &Error{Status: http.StatusUnauthorized, Code: "unauthorized", Message: i18n.T("api.error.unauthorized")})
				return
			}
		}
		if ok, wait := limiter.take(); !ok {
			writeError(w, &Error{Status: http.StatusTooManyRequests, Code: "rate_limited", Message: i18n.T("api.error.tooManyRequests"), RetryAfter: wait})
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, MaxBody)
		next.ServeHTTP(w, r)
	})
}

func bearer(h string) string {
	if len(h) > 7 && strings.EqualFold(h[:7], "Bearer ") {
		return strings.TrimSpace(h[7:])
	}
	return ""
}

func routed(mux *http.ServeMux) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if _, pattern := mux.Handler(r); pattern != "" {
			mux.ServeHTTP(w, r)
			return
		}
		var allow []string
		for _, m := range []string{http.MethodGet, http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodPatch} {
			r2 := r.Clone(r.Context())
			r2.Method = m
			if _, p := mux.Handler(r2); p != "" {
				allow = append(allow, m)
			}
		}
		if len(allow) == 0 {
			writeError(w, &Error{Status: http.StatusNotFound, Code: "not_found", Message: i18n.T("api.error.notFound")})
			return
		}
		w.Header().Set("Allow", strings.Join(allow, ", "))
		writeError(w, &Error{Status: http.StatusMethodNotAllowed, Code: "method_not_allowed", Message: i18n.T("api.error.methodNotAllowed")})
	})
}

// Error is {"error": message, "code": code, "field": field}.
type Error struct {
	Status     int
	Code       string
	Field      string
	Message    string
	RetryAfter time.Duration
}

func (e *Error) Error() string { return e.Code + ": " + e.Message }

func writeError(w http.ResponseWriter, e *Error) {
	if e.RetryAfter > 0 {
		secs := int((e.RetryAfter + time.Second - 1) / time.Second)
		w.Header().Set("Retry-After", strconv.Itoa(max(secs, 1)))
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(e.Status)
	body := map[string]string{"error": e.Message, "code": e.Code}
	if e.Field != "" {
		body["field"] = e.Field
	}
	_ = json.NewEncoder(w).Encode(body)
}

func decode(w http.ResponseWriter, r *http.Request, v any, limit int64) *Error {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	dec := json.NewDecoder(r.Body)
	err := dec.Decode(v)
	if err == nil {
		if _, terr := dec.Token(); terr != io.EOF {
			return &Error{Status: http.StatusBadRequest, Code: "invalid_json", Message: i18n.T("api.error.trailingData")}
		}
		return nil
	}
	var mbe *http.MaxBytesError
	var ute *json.UnmarshalTypeError
	switch {
	case errors.As(err, &mbe):
		return &Error{Status: http.StatusRequestEntityTooLarge, Code: "body_too_large", Message: i18n.T("api.error.bodyTooLarge")}
	case errors.As(err, &ute):
		return &Error{Status: http.StatusBadRequest, Code: "invalid_type", Field: ute.Field, Message: i18n.T("api.error.wrongType")}
	default:
		return &Error{Status: http.StatusBadRequest, Code: "invalid_json", Message: i18n.T("api.error.invalidJSON")}
	}
}

func readBody(w http.ResponseWriter, r *http.Request, limit int64) ([]byte, *Error) {
	r.Body = http.MaxBytesReader(w, r.Body, limit)
	b, err := io.ReadAll(r.Body)
	var mbe *http.MaxBytesError
	if errors.As(err, &mbe) {
		return nil, &Error{Status: http.StatusRequestEntityTooLarge, Code: "body_too_large", Message: i18n.T("api.error.bodyTooLarge")}
	}
	if err != nil {
		return nil, &Error{Status: http.StatusBadRequest, Code: "invalid_body", Message: i18n.T("api.error.unreadableBody")}
	}
	return b, nil
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_ = json.NewEncoder(w).Encode(v)
}

// MaskID shortens an identifier for display ("T3pJ…C-g"): any local process can read the API.
func MaskID(id string) string {
	if len(id) <= 8 {
		if id == "" {
			return ""
		}
		return "…"
	}
	return id[:4] + "…" + id[len(id)-3:]
}
