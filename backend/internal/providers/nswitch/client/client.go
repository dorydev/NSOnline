package client

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"strconv"
	"strings"
	"time"

	"nsonline/internal/providers"
)

// DefaultAppVersion is the NSO app version we send. Coral answers 9427 to stale ones.
const DefaultAppVersion = "3.6.0"

const (
	maxBody      = 4 << 20
	maxErrorBody = 512
)

var (
	AccountsURL = "https://accounts.nintendo.com"
	APIURL      = "https://api.accounts.nintendo.com"
	CoralURL    = "https://api-lp1.znc.srv.nintendo.net"
)

var appVersion = DefaultAppVersion

func SetAppVersion(v string) {
	if v != "" {
		appVersion = v
	}
}

func AppVersion() string { return appVersion }

type Hosts struct{ Accounts, API, Coral string }

// SetHosts is for tests: not safe while requests are in flight.
func SetHosts(h Hosts) (restore func()) {
	old := Hosts{AccountsURL, APIURL, CoralURL}
	AccountsURL, APIURL, CoralURL = h.Accounts, h.API, h.Coral
	return func() { AccountsURL, APIURL, CoralURL = old.Accounts, old.API, old.Coral }
}

type Client struct {
	HTTP    *http.Client
	Verbose bool
}

func New(verbose bool) *Client {
	return &Client{HTTP: &http.Client{Timeout: 30 * time.Second}, Verbose: verbose}
}

type APIError struct {
	Status     int
	Body       string
	RetryAfter time.Duration
}

func (e *APIError) Error() string       { return fmt.Sprintf("HTTP %d: %s", e.Status, e.Body) }
func (e *APIError) Code() int           { return e.Status }
func (e *APIError) Wait() time.Duration { return e.RetryAfter }

func (c *Client) Do(req *http.Request, out any) error {
	body, err := c.Raw(req)
	if err != nil {
		return err
	}
	if out == nil {
		return nil
	}

	if err := json.Unmarshal(body, out); err != nil {
		return fmt.Errorf("decode %s: %w (body: %s)", req.URL, err, Redact(body))
	}
	return nil
}

func (c *Client) Raw(req *http.Request) ([]byte, error) {
	if c.Verbose {
		logRequest(req)
	}

	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, maxBody+1))
	if err != nil {
		return nil, err
	}
	if len(body) > maxBody {
		return nil, fmt.Errorf("%s %s: response larger than %d MiB", req.Method, req.URL.Host, maxBody>>20)
	}
	if c.Verbose {
		log.Printf("<<< %s\n%s\n", resp.Status, printable(resp.Header.Get("Content-Type"), body))
	}

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, &APIError{
			Status:     resp.StatusCode,
			Body:       Truncate(string(Redact(body)), maxErrorBody),
			RetryAfter: ParseRetryAfter(resp.Header.Get("Retry-After"), time.Now()),
		}
	}
	return body, nil
}

func ParseRetryAfter(v string, now time.Time) time.Duration {
	if v == "" {
		return 0
	}
	if secs, err := strconv.ParseInt(v, 10, 64); err == nil && secs > 0 {
		if secs > int64(providers.MaxRetryAfter/time.Second) {
			return providers.MaxRetryAfter
		}
		return time.Duration(secs) * time.Second
	}
	if t, err := http.ParseTime(v); err == nil && t.After(now) {
		return min(t.Sub(now), providers.MaxRetryAfter)
	}
	return 0
}

func logRequest(req *http.Request) {
	ct := req.Header.Get("Content-Type")
	textual := ct == "" || strings.Contains(ct, "json") || strings.Contains(ct, "form")

	dump, err := httputil.DumpRequestOut(req, textual)
	if err != nil {
		return
	}
	if !textual && req.ContentLength > 0 {
		dump = append(dump, fmt.Sprintf("[%d bytes, %s]", req.ContentLength, ct)...)
	}
	log.Printf(">>> request\n%s\n", Redact(dump))
}

func printable(contentType string, body []byte) []byte {
	if strings.Contains(contentType, "octet-stream") || !isText(body) {
		return []byte(fmt.Sprintf("[%d bytes, %s]", len(body), contentType))
	}
	return Redact(body)
}

func isText(b []byte) bool {
	for _, c := range b {
		if c < 0x09 || (c > 0x0d && c < 0x20) || c == 0x7f {
			return false
		}
	}
	return true
}
