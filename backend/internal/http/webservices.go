package api

import (
	"context"
	"net/http"

	"nsonline/internal/providers"
	"nsonline/shared/i18n"
)

type WebService struct {
	providers.WebService
	Available bool   `json:"available"`
	Reason    string `json:"reason"`
}

type WebServiceList struct {
	Account  string       `json:"account"`
	Services []WebService `json:"services"`
}

type WebServicesBackend interface {
	WebServices() WebServiceList
	OpenWebService(ctx context.Context, id string) (*providers.WebServiceOpen, error)
}

func validServiceID(id string) bool {
	if id == "" || len(id) > 20 {
		return false
	}
	for _, c := range id {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// The open route is the one exception to "no tokens in responses": the app's
// WebView needs the web service token. It is only served with the Bearer token
// (app mode), never logged, and answered with Cache-Control: no-store.
func webServiceRoutes(mux *http.ServeMux, b WebServicesBackend) {
	mux.HandleFunc("GET /api/webservices", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, b.WebServices())
	})

	mux.HandleFunc("POST /api/webservices/{id}/open", func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		if !validServiceID(id) {
			writeError(w, &Error{Status: http.StatusNotFound, Code: "unknown_service", Message: i18n.T("api.error.unknownService")})
			return
		}

		open, err := b.OpenWebService(r.Context(), id)
		respond(w, open, err)
	})
}
