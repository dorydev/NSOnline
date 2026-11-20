package nswitch

import (
	"encoding/json"
	"errors"
	"net/url"

	"nsonline/internal/providers"
	"nsonline/internal/providers/nswitch/auth"
	"nsonline/internal/providers/nswitch/coral"
)

// WebViewUserAgent is the NSO app's Android WebView, as sent by nxapi for SplatNet 3 and NookLink.
const WebViewUserAgent = "Mozilla/5.0 (Linux; Android 8.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/58.0.3029.125 Mobile Safari/537.36"

var ErrUnknownService = errors.New("unknown web service")

type webService struct {
	providers.WebService
	id int64
}

// Ids and URLs from nxapi (src/api/splatnet3.ts, nooklink.ts). Smash World's
// URL is not in nxapi: it is read once from GameWebService/List.
var webServices = []webService{
	{providers.WebService{ID: "4834290508791808", Name: "SplatNet 3", Game: "Splatoon 3", URL: "https://api.lp1.av5ja.srv.nintendo.net/"}, 4834290508791808},
	{providers.WebService{ID: "4953919198265344", Name: "NookLink", Game: "Animal Crossing: New Horizons", URL: "https://web.sd.lp1.acbaa.srv.nintendo.net/"}, 4953919198265344},
	{providers.WebService{ID: "5598642853249024", Name: "Smash World", Game: "Super Smash Bros. Ultimate"}, 5598642853249024},
}

func findWebService(id string) (webService, bool) {
	for _, w := range webServices {
		if w.ID == id {
			return w, true
		}
	}
	return webService{}, false
}

// resolveURL reads Coral's list when a service has no known URL.
func (s *Session) resolveURL(w *webService) error {
	if w.URL != "" {
		return nil
	}

	var list []coral.WebService
	_, err := s.call(func(token string) (json.RawMessage, error) {
		var err error
		list, err = coral.WebServices(s.Client, s.Znca, token)
		return nil, err
	})
	if err != nil {
		return err
	}

	for _, l := range list {
		if l.ID == w.id {
			w.URL, w.ImageURI = l.URI, l.ImageURI
			return nil
		}
	}
	return &coral.Error{Status: coral.Forbidden, Message: "web service not in this account's list"}
}

func (s *Session) ListWebServices() ([]coral.WebService, error) {
	if _, err := s.EnsureCoral(); err != nil {
		return nil, err
	}

	var list []coral.WebService
	_, err := s.call(func(token string) (json.RawMessage, error) {
		var err error
		list, err = coral.WebServices(s.Client, s.Znca, token)
		return nil, err
	})
	return list, err
}

func (s *Session) webServiceToken(id int64) (*coral.WebServiceToken, error) {
	naID := ""
	if s.Store.Profile != nil {
		naID = s.Store.Profile.ID
	}

	var tok *coral.WebServiceToken
	_, err := s.call(func(token string) (json.RawMessage, error) {
		var err error
		tok, err = coral.GetWebServiceToken(s.Client, s.Znca, s.Store.Coral, naID, id)
		return nil, err
	})
	return tok, err
}

func (s *Session) country() string {
	st := s.Store
	if st.Profile != nil && st.Profile.Country != "" {
		return st.Profile.Country
	}

	acct, err := s.EnsureAccount()
	if err != nil {
		return ""
	}
	u, err := auth.Me(s.Client, acct.AccessToken)
	if err != nil {
		return ""
	}

	if st.Profile == nil {
		st.Profile = &auth.Profile{ID: u.ID, Language: u.Language}
	}
	st.Profile.Country = u.Country
	_ = st.Save()
	return u.Country
}

// OpenWebService gets a web service token. A rejected Coral token is renewed once.
func (s *Session) OpenWebService(id string) (*providers.WebServiceOpen, error) {
	w, ok := findWebService(id)
	if !ok {
		return nil, ErrUnknownService
	}
	if _, err := s.EnsureCoral(); err != nil {
		return nil, err
	}

	tok, err := s.webServiceToken(w.id)
	var ce *coral.Error
	if errors.As(err, &ce) && ce.Rejected() {
		if _, err = s.EnsureCoral(); err == nil {
			tok, err = s.webServiceToken(w.id)
		}
	}
	if err != nil {
		return nil, err
	}

	if err := s.resolveURL(&w); err != nil {
		return nil, err
	}

	lang := ""
	if s.Store.Profile != nil {
		lang = s.Store.Profile.Language
	}
	country := s.country()

	host := ""
	if u, err := url.Parse(w.URL); err == nil {
		host = u.Hostname()
	}

	open := &providers.WebServiceOpen{
		URL:       w.URL,
		Token:     tok.AccessToken,
		ExpiresAt: tok.ExpiresAt,
		UserAgent: WebViewUserAgent,
		Cookies:   []providers.Cookie{{Name: "_gtoken", Value: tok.AccessToken, Domain: host}},
		Headers: map[string]string{
			"X-GameWebToken":   tok.AccessToken,
			"X-AppColorScheme": "DARK",
			"X-Requested-With": "com.nintendo.znca",
			"DNT":              "1",
		},
		Query: map[string]string{"lang": lang, "na_country": country, "na_lang": lang},
	}
	if u, err := url.Parse(w.URL); err == nil {
		q := u.Query()
		for k, v := range open.Query {
			q.Set(k, v)
		}
		u.RawQuery = q.Encode()
		open.URL = u.String()
	}
	return open, nil
}
