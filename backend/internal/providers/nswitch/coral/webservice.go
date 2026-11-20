package coral

import (
	"encoding/json"
	"fmt"
	"time"

	"nsonline/internal/providers/nswitch/client"
	"nsonline/internal/providers/nswitch/znca"
)

type WebServiceToken struct {
	AccessToken string    `json:"-"`
	ExpiresAt   time.Time `json:"-"`
}

func (t *WebServiceToken) Valid() bool {
	return t != nil && t.AccessToken != "" && time.Until(t.ExpiresAt) > 5*time.Minute
}

// field order follows nxapi
type webServiceParameter struct {
	ID                int64  `json:"id"`
	RegistrationToken string `json:"registrationToken"`
	F                 string `json:"f"`
	RequestID         string `json:"requestId"`
	Timestamp         int64  `json:"timestamp"`
}

// GetWebServiceToken needs an f from the CORAL token (hash method 2).
func GetWebServiceToken(c *client.Client, z *znca.Znca, coral *Tokens, naID string, id int64) (*WebServiceToken, error) {
	const path = "/v4/Game/GetWebServiceToken"
	param := &webServiceParameter{ID: id}

	f, err := z.F(coral.AccessToken, znca.HashWebService, naID, coral.UserID, &znca.EncryptTokenRequest{URL: client.CoralURL + path, Parameter: param})
	if err != nil {
		return nil, err
	}

	body := f.EncryptedRequest
	if body == nil {
		param.F, param.Timestamp, param.RequestID = f.F, f.Timestamp, f.RequestID
		plain, _ := json.Marshal(map[string]any{"parameter": param})
		if body, err = z.EncryptRequest(client.CoralURL+path, coral.AccessToken, plain); err != nil {
			return nil, err
		}
	}

	result, err := Post(c, z, path, body, coral.AccessToken)
	if err != nil {
		return nil, err
	}

	var out struct {
		AccessToken string `json:"accessToken"`
		ExpiresIn   int    `json:"expiresIn"`
	}
	if err := json.Unmarshal(result, &out); err != nil {
		return nil, fmt.Errorf("web service token: %w", err)
	}
	if out.AccessToken == "" {
		return nil, fmt.Errorf("coral %s: no accessToken in response", path)
	}
	return &WebServiceToken{AccessToken: out.AccessToken, ExpiresAt: time.Now().Add(time.Duration(out.ExpiresIn) * time.Second)}, nil
}

type WebService struct {
	ID        int64    `json:"id"`
	URI       string   `json:"uri"`
	Name      string   `json:"name"`
	ImageURI  string   `json:"imageUri"`
	WhiteList []string `json:"whiteList"`
}

// WebServices is GameWebService/List: no parameter, only a request id.
func WebServices(c *client.Client, z *znca.Znca, coralToken string) ([]WebService, error) {
	plain, _ := json.Marshal(map[string]string{"requestId": uuid()})
	raw, err := send(c, z, coralToken, "/v4/GameWebService/List", plain)
	if err != nil {
		return nil, err
	}

	var list []WebService
	if err := json.Unmarshal(raw, &list); err != nil {
		return nil, fmt.Errorf("web services: %w", err)
	}
	return list, nil
}
