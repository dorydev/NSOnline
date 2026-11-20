// Package discord is a minimal Rich Presence client over the Discord IPC socket.
package discord

import (
	"crypto/rand"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"
)

const (
	opHandshake uint32 = 0
	opFrame     uint32 = 1
	opClose     uint32 = 2
	opPing      uint32 = 3
	opPong      uint32 = 4
)

const (
	Playing   = 0
	Listening = 2
	Watching  = 3
	Competing = 5
)

// StatusDisplayType picks what the status shows ("Playing <…>"): the app name, the state or the details.
const (
	DisplayName    = 0
	DisplayState   = 1
	DisplayDetails = 2
)

type Timestamps struct {
	Start int64 `json:"start,omitempty"` // unix seconds
	End   int64 `json:"end,omitempty"`
}

type Assets struct {
	LargeImage string `json:"large_image,omitempty"` // asset key or https URL
	LargeText  string `json:"large_text,omitempty"`
	SmallImage string `json:"small_image,omitempty"`
	SmallText  string `json:"small_text,omitempty"`
}

type Party struct {
	ID   string `json:"id,omitempty"`
	Size []int  `json:"size,omitempty"`
}

type Button struct {
	Label string `json:"label"`
	URL   string `json:"url"`
}

type Activity struct {
	Type              int         `json:"type"`
	Details           string      `json:"details,omitempty"`
	State             string      `json:"state,omitempty"`
	Timestamps        *Timestamps `json:"timestamps,omitempty"`
	Assets            *Assets     `json:"assets,omitempty"`
	Party             *Party      `json:"party,omitempty"`
	Buttons           []Button    `json:"buttons,omitempty"` // max 2
	StatusDisplayType int         `json:"status_display_type,omitempty"`
}

type Client struct {
	clientID string
	conn     io.ReadWriteCloser
	mu       sync.Mutex // serialises writes
	User     User
}

type User struct {
	ID       string `json:"id"`
	Username string `json:"username"`
}

type message struct {
	Cmd   string          `json:"cmd"`
	Evt   string          `json:"evt"`
	Nonce string          `json:"nonce"`
	Data  json.RawMessage `json:"data"`
}

func Connect(clientID string) (*Client, error) {
	if clientID == "" {
		return nil, errors.New("discord: empty client ID")
	}
	conn, err := dial()
	if err != nil {
		return nil, fmt.Errorf("discord: cannot reach the Discord app (is it running?): %w", err)
	}
	c := &Client{clientID: clientID, conn: conn}

	var op uint32
	var payload []byte
	err = c.withTimeout(func() error {
		if err := c.send(opHandshake, map[string]any{"v": 1, "client_id": clientID}); err != nil {
			return err
		}
		var rerr error
		op, payload, rerr = c.read()
		return rerr
	})
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("discord: handshake: %w", err)
	}
	if op == opClose {
		conn.Close()
		return nil, fmt.Errorf("discord: handshake rejected: %s", payload)
	}
	var ready message
	if err := json.Unmarshal(payload, &ready); err != nil || ready.Evt != "READY" {
		conn.Close()
		return nil, fmt.Errorf("discord: unexpected handshake reply: %s", payload)
	}
	var data struct {
		User User `json:"user"`
	}
	_ = json.Unmarshal(ready.Data, &data)
	c.User = data.User
	return c, nil
}

// SetActivity(nil) clears the presence. It gives up after Timeout.
func (c *Client) SetActivity(a *Activity) error {
	return c.withTimeout(func() error { return c.setActivity(a) })
}

func (c *Client) setActivity(a *Activity) error {
	nonce := newNonce()
	err := c.send(opFrame, map[string]any{
		"cmd":   "SET_ACTIVITY",
		"nonce": nonce,
		"args": map[string]any{
			"pid":      os.Getpid(),
			"activity": a,
		},
	})
	if err != nil {
		return err
	}
	for {
		op, payload, err := c.read()
		if err != nil {
			return err
		}
		switch op {
		case opPing:
			if err := c.write(opPong, payload); err != nil {
				return err
			}
			continue
		case opClose:
			return fmt.Errorf("discord: connection closed: %s", payload)
		}
		var m message
		if err := json.Unmarshal(payload, &m); err != nil {
			return err
		}
		if m.Nonce != nonce {
			continue
		}
		if m.Evt == "ERROR" {
			return fmt.Errorf("discord: SET_ACTIVITY error: %s", m.Data)
		}
		return nil
	}
}

func (c *Client) Close() error {
	_ = c.write(opClose, []byte("{}"))
	return c.conn.Close()
}

func (c *Client) send(op uint32, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return c.write(op, b)
}

func (c *Client) write(op uint32, payload []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	buf := make([]byte, 8+len(payload))
	binary.LittleEndian.PutUint32(buf[0:4], op)
	binary.LittleEndian.PutUint32(buf[4:8], uint32(len(payload)))
	copy(buf[8:], payload)
	_, err := c.conn.Write(buf)
	return err
}

func (c *Client) read() (uint32, []byte, error) {
	var hdr [8]byte
	if _, err := io.ReadFull(c.conn, hdr[:]); err != nil {
		return 0, nil, err
	}
	op := binary.LittleEndian.Uint32(hdr[0:4])
	n := binary.LittleEndian.Uint32(hdr[4:8])
	if n > 1<<20 {
		return 0, nil, fmt.Errorf("discord: frame too large (%d bytes)", n)
	}
	payload := make([]byte, n)
	if _, err := io.ReadFull(c.conn, payload); err != nil {
		return 0, nil, err
	}
	return op, payload, nil
}

// Timeout: a Discord that never answers must not block the loop (and Ctrl+C) forever.
var Timeout = 5 * time.Second

var errTimeout = errors.New("discord: no answer from the Discord app (timeout)")

// withTimeout uses socket deadlines, else closes the connection to unblock f.
func (c *Client) withTimeout(f func() error) error {
	if dl, ok := c.conn.(interface{ SetDeadline(time.Time) error }); ok && dl.SetDeadline(time.Now().Add(Timeout)) == nil {
		defer dl.SetDeadline(time.Time{})
		err := f()
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			return errTimeout
		}
		return err
	}
	done := make(chan error, 1)
	go func() { done <- f() }()
	select {
	case err := <-done:
		return err
	case <-time.After(Timeout):
		c.conn.Close()
		return errTimeout
	}
}

func newNonce() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
