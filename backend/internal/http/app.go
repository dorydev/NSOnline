package api

import (
	"context"
	"errors"
	"net/http"
	"strings"

	"nsonline/internal/modules/diagnostics"
	"nsonline/internal/modules/settings"
	"nsonline/internal/presence"
	"nsonline/shared/i18n"
)

// AppBackend is the sidecar (`nsonline app`). Methods that need Nintendo run
// on its owner goroutine and return *Error for answers other than 500.
type AppBackend interface {
	Backend
	Settings() settings.Settings
	PutSettings(settings.Settings) (settings.Settings, error)
	RollbackSettings() (settings.Settings, error)
	Ack(ctx context.Context) (presence.Status, error)
	LoginStart(account string) (LoginStart, error)
	LoginComplete(ctx context.Context, account, redirect string) (presence.Status, error)
	Logout(ctx context.Context, account string) (presence.Status, error)
	TestDiscord() DiscordTest
	Diagnostics(ctx context.Context) (diagnostics.Report, error)
	Shutdown()
}

type LoginStart struct {
	URL            string `json:"url"`
	RedirectPrefix string `json:"redirectPrefix"`
}

type DiscordTest struct {
	OK             bool   `json:"ok"`
	DiscordRunning bool   `json:"discordRunning"`
	Error          string `json:"error"`
}

const (
	AccountObserver = "observer"
	AccountMain     = "main"
	AccountAll      = "all"
)

const maxRedirect = 4096

func appRoutes(mux *http.ServeMux, b AppBackend) {
	mux.HandleFunc("GET /api/settings", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, b.Settings()) })
	mux.HandleFunc("PUT /api/settings", func(w http.ResponseWriter, r *http.Request) {
		raw, e := readBody(w, r, MaxBody)
		if e != nil {
			writeError(w, e)
			return
		}
		s, err := settings.ParseStrict(raw)
		if err != nil {
			writeError(w, asError(err))
			return
		}
		out, err := b.PutSettings(s)
		respond(w, out, err)
	})
	mux.HandleFunc("POST /api/settings/rollback", func(w http.ResponseWriter, r *http.Request) {
		out, err := b.RollbackSettings()
		respond(w, out, err)
	})
	mux.HandleFunc("POST /api/ack", func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Accepted *bool `json:"accepted"`
		}
		if e := decode(w, r, &body, 1<<10); e != nil {
			writeError(w, e)
			return
		}
		if body.Accepted == nil || !*body.Accepted {
			writeError(w, &Error{Status: http.StatusBadRequest, Code: "not_accepted", Field: "accepted", Message: i18n.T("api.error.expectedAccepted")})
			return
		}
		st, err := b.Ack(r.Context())
		respond(w, st, err)
	})
	mux.HandleFunc("POST /api/login/start", func(w http.ResponseWriter, r *http.Request) {
		account, e := accountBody(w, r, false, nil)
		if e != nil {
			writeError(w, e)
			return
		}
		out, err := b.LoginStart(account)
		respond(w, out, err)
	})
	mux.HandleFunc("POST /api/login/complete", func(w http.ResponseWriter, r *http.Request) {
		var redirect string
		account, e := accountBody(w, r, false, &redirect)
		if e != nil {
			writeError(w, e)
			return
		}
		st, err := b.LoginComplete(r.Context(), account, redirect)
		respond(w, st, err)
	})
	mux.HandleFunc("POST /api/logout", func(w http.ResponseWriter, r *http.Request) {
		account, e := accountBody(w, r, true, nil)
		if e != nil {
			writeError(w, e)
			return
		}
		st, err := b.Logout(r.Context(), account)
		respond(w, st, err)
	})
	mux.HandleFunc("POST /api/discord/test", func(w http.ResponseWriter, r *http.Request) { writeJSON(w, b.TestDiscord()) })
	mux.HandleFunc("POST /api/diagnostics", func(w http.ResponseWriter, r *http.Request) {
		d, err := b.Diagnostics(r.Context())
		respond(w, d, err)
	})
	mux.HandleFunc("POST /api/shutdown", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"ok":true}` + "\n"))
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		b.Shutdown()
	})
}

func accountBody(w http.ResponseWriter, r *http.Request, allowAll bool, redirect *string) (string, *Error) {
	var body struct {
		Account  *string `json:"account"`
		Redirect *string `json:"redirect"`
	}
	if e := decode(w, r, &body, MaxBody); e != nil {
		return "", e
	}
	if body.Account == nil {
		return "", &Error{Status: http.StatusBadRequest, Code: "missing_field", Field: "account", Message: i18n.T("api.error.fieldRequired", i18n.Args{"field": "account"})}
	}
	switch a := *body.Account; {
	case a == AccountObserver, a == AccountMain, a == AccountAll && allowAll:
	default:
		key := "api.error.accountObserverMain"
		if allowAll {
			key = "api.error.accountObserverMainAll"
		}
		return "", &Error{Status: http.StatusBadRequest, Code: "invalid_account", Field: "account", Message: i18n.T(key)}
	}
	if redirect != nil {
		if body.Redirect == nil || strings.TrimSpace(*body.Redirect) == "" {
			return "", &Error{Status: http.StatusBadRequest, Code: "missing_field", Field: "redirect", Message: i18n.T("api.error.fieldRequired", i18n.Args{"field": "redirect"})}
		}
		if len(*body.Redirect) > maxRedirect {
			return "", &Error{Status: http.StatusBadRequest, Code: "invalid_redirect", Field: "redirect", Message: i18n.T("api.error.redirectTooLong")}
		}
		*redirect = *body.Redirect
	}
	return *body.Account, nil
}

func respond(w http.ResponseWriter, v any, err error) {
	if err != nil {
		writeError(w, asError(err))
		return
	}
	writeJSON(w, v)
}

// asError hides unexpected errors behind a generic 500: they may carry paths.
func asError(err error) *Error {
	var e *Error
	if errors.As(err, &e) {
		return e
	}
	var fe *settings.FieldError
	if errors.As(err, &fe) {
		return &Error{Status: http.StatusBadRequest, Code: fe.Code, Field: fe.Field, Message: fe.Message}
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return &Error{Status: http.StatusGatewayTimeout, Code: "timeout", Message: i18n.T("api.error.timeout")}
	}
	return &Error{Status: http.StatusInternalServerError, Code: "internal", Message: i18n.T("api.error.internal")}
}
