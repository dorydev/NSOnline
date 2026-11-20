package sidecar

import (
	"context"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	api "nsonline/internal/http"
	"nsonline/internal/providers"
	"nsonline/internal/providers/nswitch"
	"nsonline/internal/providers/nswitch/coral"
	"nsonline/shared/i18n"
)

// webTokenMargin: a cached token is reused only if the WebView keeps it this long.
const webTokenMargin = 5 * time.Minute

// Coral's service list only gives the card images: one call a day is plenty.
const (
	webImagesEvery = 24 * time.Hour
	webImagesRetry = time.Hour
)

func notLoggedIn() *api.Error {
	return &api.Error{Status: http.StatusConflict, Code: "not_logged_in", Message: i18n.T("api.error.webServiceNotLoggedIn")}
}

func unknownService() *api.Error {
	return &api.Error{Status: http.StatusNotFound, Code: "unknown_service", Message: i18n.T("api.error.unknownService")}
}

func webError(ctx context.Context, err error) error {
	var ce *coral.Error
	switch {
	case ctx.Err() != nil:
		return errTimeout()
	case errors.Is(err, nswitch.ErrUnknownService):
		return unknownService()
	case errors.Is(err, nswitch.ErrNotLoggedIn):
		return notLoggedIn()
	case errors.As(err, &ce) && (ce.Status == coral.Forbidden || ce.Status == coral.Unauthorised || ce.Status == coral.MembershipReq):
		return &api.Error{Status: http.StatusForbidden, Code: "not_owned", Message: i18n.T("api.error.webServiceNotOwned")}
	case errors.As(err, &ce) && ce.Status == coral.RateLimited, providers.ErrorCode(err) == http.StatusTooManyRequests:
		return &api.Error{Status: http.StatusTooManyRequests, Code: "rate_limited", Message: i18n.T("api.error.tooManyRequests"), RetryAfter: providers.RetryAfter(err)}
	}

	e := upstreamError()
	e.RetryAfter = providers.RetryAfter(err)
	return e
}

// webAccount picks the main account, else the observer. Read side: copies only.
func (s *Supervisor) webAccount() (name, reason string) {
	s.mu.RLock()
	obs, mainAcct, mainAck, ack := s.obsTokens.Session, s.mainAccount.Connected, s.mainAck, s.ack
	s.mu.RUnlock()

	switch {
	case mainAcct && mainAck:
		name = api.AccountMain
	case obs:
		name = api.AccountObserver
	case mainAcct:
		name = api.AccountMain
	default:
		return "none", "not_logged_in"
	}

	switch {
	case s.cfg.Znca.ClientID == "":
		return name, "znca_not_configured"
	case name == api.AccountObserver && !ack, name == api.AccountMain && !mainAck:
		return name, "consent_required"
	}
	return name, ""
}

func (s *Supervisor) WebServices() api.WebServiceList {
	name, reason := s.webAccount()
	if reason == "" {
		s.maybeFetchWebImages(name)
	}

	s.mu.RLock()
	images := s.webImages
	s.mu.RUnlock()

	list := api.WebServiceList{Account: name, Services: []api.WebService{}}
	for _, w := range nswitch.New(s.cfg.Znca, false).WebServices() {
		if w.ImageURI == "" {
			w.ImageURI = images[w.ID]
		}
		list.Services = append(list.Services, api.WebService{WebService: w, Available: reason == "", Reason: reason})
	}
	return list
}

func (s *Supervisor) maybeFetchWebImages(name string) {
	s.mu.Lock()
	wait := webImagesEvery
	if len(s.webImages) == 0 {
		wait = webImagesRetry
	}
	if s.webImagesOn || (!s.webImagesAt.IsZero() && s.cfg.Now().Sub(s.webImagesAt) < wait) {
		s.mu.Unlock()
		return
	}
	s.webImagesOn = true
	s.mu.Unlock()

	go s.fetchWebImages(name)
}

func (s *Supervisor) fetchWebImages(name string) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()

	images := map[string]string{}
	err := s.do(ctx, func(ctx context.Context) error {
		list, err := s.account(name).ListWebServices()
		if err != nil {
			return err
		}
		for _, l := range list {
			if strings.HasPrefix(l.ImageURI, "https://") {
				images[strconv.FormatInt(l.ID, 10)] = l.ImageURI
			}
		}
		return nil
	})
	if err != nil {
		log.Printf("web service images: %v", err)
	}

	s.mu.Lock()
	s.webImagesOn = false
	s.webImagesAt = s.cfg.Now()
	if len(images) > 0 {
		s.webImages = images
	}
	s.mu.Unlock()
}

func (s *Supervisor) cachedWebToken(key string) *providers.WebServiceOpen {
	s.mu.RLock()
	defer s.mu.RUnlock()

	t := s.webTokens[key]
	if t == nil || s.cfg.Now().Add(webTokenMargin).After(t.ExpiresAt) {
		return nil
	}
	cp := *t
	return &cp
}

func (s *Supervisor) forgetWebTokens(account string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	for key := range s.webTokens {
		if len(key) > len(account) && key[:len(account)+1] == account+":" {
			delete(s.webTokens, key)
		}
	}
}

// OpenWebService fetches a web service token only when the user opens the
// service (no polling), on the owner goroutine, and caches it until it expires.
func (s *Supervisor) OpenWebService(ctx context.Context, id string) (*providers.WebServiceOpen, error) {
	known := false
	for _, w := range nswitch.New(s.cfg.Znca, false).WebServices() {
		known = known || w.ID == id
	}
	if !known {
		return nil, unknownService()
	}

	name, reason := s.webAccount()
	switch reason {
	case "":
	case "not_logged_in":
		return nil, notLoggedIn()
	default:
		return nil, &api.Error{Status: http.StatusConflict, Code: reason, Message: i18n.T("api.error.webServiceUnavailable")}
	}

	key := name + ":" + id
	if t := s.cachedWebToken(key); t != nil {
		return t, nil
	}

	var open *providers.WebServiceOpen
	err := s.do(ctx, func(ctx context.Context) error {
		a := s.account(name)
		var err error
		open, err = a.OpenWebService(id)
		if err != nil {
			log.Printf("web service %s (%s): %v", id, name, err)
			return webError(ctx, err)
		}
		log.Printf("web service %s (%s): token ready", id, name)
		return nil
	})
	if err != nil {
		return nil, err
	}

	s.mu.Lock()
	s.webTokens[key] = open
	s.mu.Unlock()

	cp := *open
	return &cp, nil
}
