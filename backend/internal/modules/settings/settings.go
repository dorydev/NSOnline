package settings

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode"
	"unicode/utf8"

	"nsonline/internal/atomicfile"
	"nsonline/shared/i18n"
)

// The floor matches presence.MinInterval.
const (
	MinSeconds   = 15
	MaxSeconds   = 3600
	MaxTargetLen = 64
)

const (
	FileName   = "settings.json"
	BackupName = "settings.json.bak"
)

// Settings is settings.json and GET/PUT /api/settings. Language is optional
// ("" = not chosen): the CLI uses it when neither --lang nor NSONLINE_LANG is set.
type Settings struct {
	WatchTarget            string `json:"watchTarget"`
	IntervalSeconds        int    `json:"intervalSeconds"`
	IdleIntervalSeconds    int    `json:"idleIntervalSeconds"`
	FriendsIntervalSeconds int    `json:"friendsIntervalSeconds"`
	ShowIdle               bool   `json:"showIdle"`
	DiscordEnabled         bool   `json:"discordEnabled"`
	Language               string `json:"language,omitempty"`
}

func Defaults() Settings {
	return Settings{IntervalSeconds: 15, IdleIntervalSeconds: 15, FriendsIntervalSeconds: 30, ShowIdle: true, DiscordEnabled: true}
}

type FieldError struct {
	Field   string
	Code    string
	Message string
}

func (e *FieldError) Error() string { return e.Field + ": " + e.Message }

func (s Settings) Validate() error {
	for _, f := range []struct {
		name string
		v    int
	}{
		{"intervalSeconds", s.IntervalSeconds},
		{"idleIntervalSeconds", s.IdleIntervalSeconds},
		{"friendsIntervalSeconds", s.FriendsIntervalSeconds},
	} {
		if f.v < MinSeconds || f.v > MaxSeconds {
			return &FieldError{f.name, "out_of_range", i18n.T("api.settings.outOfRange", i18n.Args{"min": MinSeconds, "max": MaxSeconds})}
		}
	}
	t := s.WatchTarget
	if t != strings.TrimSpace(t) || !utf8.ValidString(t) || utf8.RuneCountInString(t) > MaxTargetLen {
		return &FieldError{"watchTarget", "invalid_value", i18n.T("api.settings.invalidTarget", i18n.Args{"max": MaxTargetLen})}
	}
	for _, r := range t {
		if unicode.IsControl(r) || r == '/' || r == '\\' {
			return &FieldError{"watchTarget", "invalid_value", i18n.T("api.settings.forbiddenChar")}
		}
	}
	if s.Language != "" && !validLanguage(s.Language) {
		return &FieldError{"language", "invalid_value", i18n.T("api.settings.invalidLanguage")}
	}
	return nil
}

func validLanguage(code string) bool {
	for _, l := range i18n.Locales() {
		if l == code {
			return true
		}
	}
	return false
}

var fields = []string{"watchTarget", "intervalSeconds", "idleIntervalSeconds", "friendsIntervalSeconds", "showIdle", "discordEnabled"}

// ParseStrict decodes PUT /api/settings: every field but language is required
// with the right JSON type, unknown fields are ignored (a newer app may send more).
func ParseStrict(b []byte) (Settings, error) {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(b, &raw); err != nil || raw == nil {
		return Settings{}, &FieldError{"", "invalid_json", i18n.T("api.settings.expectedObject")}
	}
	var s Settings
	targets := map[string]any{
		"watchTarget": &s.WatchTarget, "intervalSeconds": &s.IntervalSeconds,
		"idleIntervalSeconds": &s.IdleIntervalSeconds, "friendsIntervalSeconds": &s.FriendsIntervalSeconds,
		"showIdle": &s.ShowIdle, "discordEnabled": &s.DiscordEnabled,
	}
	for _, name := range fields {
		v, ok := raw[name]
		if !ok || string(v) == "null" {
			return Settings{}, &FieldError{name, "missing_field", i18n.T("api.error.fieldRequired", i18n.Args{"field": name})}
		}
		if err := json.Unmarshal(v, targets[name]); err != nil {
			return Settings{}, &FieldError{name, "invalid_type", i18n.T("api.error.wrongType")}
		}
	}
	if v, ok := raw["language"]; ok && string(v) != "null" {
		if err := json.Unmarshal(v, &s.Language); err != nil {
			return Settings{}, &FieldError{"language", "invalid_type", i18n.T("api.error.wrongType")}
		}
	}
	return s, s.Validate()
}

// parseFile is lenient: missing fields keep their defaults (older files).
func parseFile(b []byte) (Settings, error) {
	s := Defaults()
	if err := json.Unmarshal(b, &s); err != nil {
		return Settings{}, err
	}
	return s, s.Validate()
}

var ErrNoBackup = errors.New("no settings backup")

type Store struct {
	dir string
	mu  sync.Mutex
}

func NewStore(dir string) *Store { return &Store{dir: dir} }

func (st *Store) path() string   { return filepath.Join(st.dir, FileName) }
func (st *Store) backup() string { return filepath.Join(st.dir, BackupName) }

// Load falls back to the backup when settings.json is corrupt, then to the defaults.
func (st *Store) Load() Settings {
	st.mu.Lock()
	defer st.mu.Unlock()
	for _, p := range []string{st.path(), st.backup()} {
		b, err := os.ReadFile(p)
		if errors.Is(err, fs.ErrNotExist) {
			if p == st.path() {
				return Defaults()
			}
			continue
		}
		if err == nil {
			var s Settings
			if s, err = parseFile(b); err == nil {
				return s
			}
		}
		log.Printf("settings: %s unusable (%v)", filepath.Base(p), err)
	}
	return Defaults()
}

// Save keeps the current settings.json as settings.json.bak, then writes s.
func (st *Store) Save(s Settings) error {
	if err := s.Validate(); err != nil {
		return err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if cur, err := os.ReadFile(st.path()); err == nil {
		if _, perr := parseFile(cur); perr == nil {
			if err := atomicfile.Write(st.backup(), cur, 0o600); err != nil {
				return err
			}
		}
	}
	return st.write(st.path(), s)
}

// SaveQuiet leaves the backup alone: a toggle must not overwrite the last real change.
func (st *Store) SaveQuiet(s Settings) error {
	if err := s.Validate(); err != nil {
		return err
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.write(st.path(), s)
}

// Rollback swaps settings.json and the backup, so a second rollback undoes the first.
func (st *Store) Rollback() (Settings, error) {
	st.mu.Lock()
	defer st.mu.Unlock()
	b, err := os.ReadFile(st.backup())
	if errors.Is(err, fs.ErrNotExist) {
		return Settings{}, ErrNoBackup
	}
	if err != nil {
		return Settings{}, err
	}
	restored, err := parseFile(b)
	if err != nil {
		return Settings{}, fmt.Errorf("settings backup unusable: %w", err)
	}
	if cur, err := os.ReadFile(st.path()); err == nil {
		if _, perr := parseFile(cur); perr == nil {
			if err := atomicfile.Write(st.backup(), cur, 0o600); err != nil {
				return Settings{}, err
			}
		}
	}
	return restored, st.write(st.path(), restored)
}

func (st *Store) write(path string, s Settings) error {
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return atomicfile.Write(path, append(b, '\n'), 0o600)
}
