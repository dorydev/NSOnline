package setup

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"

	"nsonline/internal/modules/settings"
	"nsonline/shared/i18n"
)

var errNoRaw = errors.New("raw mode unavailable")

var intervalPresets = []int{15, 20, 30, 45, 60, 90, 120, 300, 600, 1800, 3600}

type keyKind int

const (
	keyNone keyKind = iota
	keyUp
	keyDown
	keyLeft
	keyRight
	keyEnter
	keyEsc
	keyCtrlC
	keyRune
)

type key struct {
	kind keyKind
	r    rune
}

// decodeKeys splits one read into keys. A lone ESC is a key only when it
// ends the read; a read with several printable runes is a paste and ignored.
func decodeKeys(b []byte) []key {
	var keys []key
	runes := 0
	for i := 0; i < len(b); {
		c := b[i]
		switch {
		case c == 0x1b:
			k, n := decodeEscape(b[i:])
			keys = append(keys, k)
			i += n
		case c == 0x03:
			keys = append(keys, key{kind: keyCtrlC})
			i++
		case c == '\r' || c == '\n':
			keys = append(keys, key{kind: keyEnter})
			i++
			if c == '\r' && i < len(b) && b[i] == '\n' {
				i++
			}
		case c < 0x20 || c == 0x7f:
			i++
		default:
			r, n := utf8.DecodeRune(b[i:])
			i += n
			if r != utf8.RuneError && unicode.IsPrint(r) {
				keys = append(keys, key{kind: keyRune, r: r})
				runes++
			}
		}
	}
	if runes > 1 {
		return nil
	}
	return keys
}

func decodeEscape(b []byte) (key, int) {
	if len(b) == 1 {
		return key{kind: keyEsc}, 1
	}

	switch b[1] {
	case '[':
		i := 2
		for i < len(b) && b[i] >= 0x20 && b[i] <= 0x3f {
			i++
		}
		if i == len(b) {
			return key{}, i
		}
		return arrow(b[i]), i + 1
	case 'O':
		if len(b) < 3 {
			return key{}, len(b)
		}
		return arrow(b[2]), 3
	case 0x1b:
		return key{}, 1
	}
	_, n := utf8.DecodeRune(b[1:])
	return key{}, 1 + n
}

func arrow(final byte) key {
	switch final {
	case 'A':
		return key{kind: keyUp}
	case 'B':
		return key{kind: keyDown}
	case 'C':
		return key{kind: keyRight}
	case 'D':
		return key{kind: keyLeft}
	}
	return key{}
}

const (
	rowTarget = iota
	rowInterval
	rowIdle
	rowFriends
	rowShowIdle
	rowDiscord
	rowLanguage
	rowSave
	rowCancel
	rowCount
)

type action int

const (
	actNone action = iota
	actEditTarget
	actSave
	actCancel
)

type tuiState struct {
	orig, draft settings.Settings
	cursor      int
	confirm     bool
	action      action
}

func (s tuiState) dirty() bool { return s.draft != s.orig }

func stepSeconds(v, dir int) int {
	next := v
	if dir > 0 {
		for _, p := range intervalPresets {
			if p > v {
				next = p
				break
			}
		}
	} else {
		for _, p := range intervalPresets {
			if p < v {
				next = p
			}
		}
	}
	return max(settings.MinSeconds, min(settings.MaxSeconds, next))
}

func stepLanguage(code string, dir int) string {
	codes := []string{""}
	for _, l := range languages {
		codes = append(codes, l.code)
	}
	i := 0
	for j, c := range codes {
		if c == code {
			i = j
		}
	}
	return codes[(i+dir+len(codes))%len(codes)]
}

func (s tuiState) step(dir int) tuiState {
	d := &s.draft
	switch s.cursor {
	case rowInterval:
		d.IntervalSeconds = stepSeconds(d.IntervalSeconds, dir)
	case rowIdle:
		d.IdleIntervalSeconds = stepSeconds(d.IdleIntervalSeconds, dir)
	case rowFriends:
		d.FriendsIntervalSeconds = stepSeconds(d.FriendsIntervalSeconds, dir)
	case rowShowIdle:
		d.ShowIdle = !d.ShowIdle
	case rowDiscord:
		d.DiscordEnabled = !d.DiscordEnabled
	case rowLanguage:
		d.Language = stepLanguage(d.Language, dir)
	}
	return s
}

func (s tuiState) cancel() tuiState {
	if s.dirty() {
		s.confirm = true
	} else {
		s.action = actCancel
	}
	return s
}

func isKey(r rune, words string) bool {
	return isAnswer(string(r), words)
}

func reduce(s tuiState, k key) tuiState {
	if s.confirm {
		switch {
		case k.kind == keyCtrlC, k.kind == keyRune && (k.r == 'y' || isKey(k.r, "cli.prompt.yesWords")):
			s.confirm, s.action = false, actCancel
		case k.kind == keyEsc, k.kind == keyRune && (k.r == 'n' || isKey(k.r, "cli.prompt.noWords")):
			s.confirm = false
		}
		return s
	}

	switch k.kind {
	case keyUp:
		s.cursor = (s.cursor + rowCount - 1) % rowCount
	case keyDown:
		s.cursor = (s.cursor + 1) % rowCount
	case keyLeft:
		return s.step(-1)
	case keyRight:
		return s.step(1)
	case keyEsc, keyCtrlC:
		return s.cancel()
	case keyEnter:
		switch s.cursor {
		case rowTarget:
			s.action = actEditTarget
		case rowSave:
			s.action = actSave
		case rowCancel:
			return s.cancel()
		default:
			return s.step(1)
		}
	case keyRune:
		switch {
		case k.r == 'k':
			s.cursor = (s.cursor + rowCount - 1) % rowCount
		case k.r == 'j':
			s.cursor = (s.cursor + 1) % rowCount
		case k.r == 's' || isKey(k.r, "cli.config.saveWords"):
			s.action = actSave
		case k.r == 'c' || k.r == 'q' || isKey(k.r, "cli.config.cancelWords"):
			return s.cancel()
		}
	}
	return s
}

func (s tuiState) lines(h header, m colorMode, cols int) []string {
	out := append(h.lines(m, cols), "")

	rows, orig := settingRows(s.draft), settingRows(s.orig)
	width := 0
	for _, r := range rows {
		width = max(width, utf8.RuneCountInString(r[0]))
	}
	pointer := func(row int, text string) string {
		if row == s.cursor {
			return m.style("36", "❯") + " " + m.style("1;7", " "+text+" ")
		}
		return "   " + text + " "
	}

	for i, r := range rows {
		label := r[0] + strings.Repeat(" ", width-utf8.RuneCountInString(r[0]))
		value := r[1]
		if i == s.cursor && i != rowTarget {
			value = "‹ " + value + " ›"
		}
		line := "  " + pointer(i, label) + "  " + value
		if r[1] != orig[i][1] {
			line += " " + m.style("33", "•")
		}
		out = append(out, line)
	}

	out = append(out, "", "  "+pointer(rowSave, i18n.T("cli.config.save")), "  "+pointer(rowCancel, i18n.T("cli.config.cancel")), "")
	if s.confirm {
		out = append(out, "  "+m.style("1;33", i18n.T("cli.config.discardAsk")))
	}
	return out
}

// render redraws from the top, fitted to the window: no logo when it's too
// narrow or too short, lines cut instead of wrapping (wrapped lines broke the
// redraw and the menu vanished on resize).
func (s tuiState) render(w io.Writer, h header, m colorMode, cols, rows int) {
	lines := s.lines(h, m, cols)
	if rows > 0 && len(lines) > rows {
		lines = s.lines(h, m, 1)
	}
	if rows > 0 && len(lines) > rows {
		lines = lines[:rows]
	}

	var sb strings.Builder
	sb.WriteString("\x1b[H")
	for i, l := range lines {
		if cols > 0 {
			l = cut(l, cols-1)
		}
		sb.WriteString(l + "\x1b[K")
		if i < len(lines)-1 {
			sb.WriteString("\r\n")
		}
	}
	sb.WriteString("\x1b[J")
	io.WriteString(w, sb.String())
}

type rawSwitch interface {
	raw() error
	cooked()
}

type tui struct {
	in     io.Reader
	out    io.Writer
	screen rawSwitch
	head   header
	mode   colorMode
	size   func() (cols, rows int)

	mu  sync.Mutex
	cur tuiState
}

func (u *tui) draw(s tuiState) {
	u.mu.Lock()
	defer u.mu.Unlock()

	u.cur = s
	cols, rows := 0, 0
	if u.size != nil {
		cols, rows = u.size()
	}
	s.render(u.out, u.head, u.mode, cols, rows)
}

// watchSize redraws when the window is resized (polling works on every OS,
// Windows has no SIGWINCH).
func (u *tui) watchSize(stop <-chan struct{}) {
	if u.size == nil {
		return
	}
	cols, rows := u.size()
	t := time.NewTicker(200 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			c, r := u.size()
			if c == cols && r == rows {
				continue
			}
			cols, rows = c, r
			u.mu.Lock()
			s := u.cur
			u.mu.Unlock()
			u.draw(s)
		}
	}
}

// run reads keys until Save or Cancel. It redraws only when the state changed.
func (u *tui) run(s tuiState) (tuiState, error) {
	buf := make([]byte, 256)
	stop := make(chan struct{})
	defer close(stop)
	go u.watchSize(stop)

	u.draw(s)
	for {
		n, err := u.in.Read(buf)
		if n == 0 && err != nil {
			return s, ErrCanceled
		}

		for _, k := range decodeKeys(buf[:n]) {
			next := reduce(s, k)
			switch next.action {
			case actSave, actCancel:
				return next, nil
			case actEditTarget:
				next.action = actNone
				u.screen.cooked()
				err := newTerm(u.in, u.out).editTarget(&next.draft)
				if rerr := u.screen.raw(); err == nil {
					err = rerr
				}
				if err != nil {
					return s, err
				}
				s = next
				u.draw(s)
				continue
			}
			if next != s {
				s = next
				u.draw(s)
			}
		}
	}
}

type screen struct {
	mu      sync.Mutex
	in, out *os.File
	restore func()
	closed  bool
}

func (sc *screen) raw() error {
	sc.mu.Lock()
	defer sc.mu.Unlock()
	if sc.restore != nil {
		return nil
	}
	r, err := makeRaw(sc.in, sc.out)
	if err != nil {
		return err
	}
	sc.restore = r
	io.WriteString(sc.out, "\x1b[?25l")
	return nil
}

func (sc *screen) cooked() {
	sc.mu.Lock()
	defer sc.mu.Unlock()
	if sc.restore != nil {
		sc.restore()
		sc.restore = nil
	}
	io.WriteString(sc.out, "\x1b[?25h")
}

func (sc *screen) open() error {
	if err := sc.raw(); err != nil {
		return err
	}
	io.WriteString(sc.out, "\x1b[?1049h")
	return nil
}

func (sc *screen) close() {
	sc.cooked()
	sc.mu.Lock()
	defer sc.mu.Unlock()
	if !sc.closed {
		sc.closed = true
		io.WriteString(sc.out, "\x1b[?1049l")
	}
}

func interactive(d Deps) (in, out *os.File, ok bool) {
	in, _ = d.In.(*os.File)
	out, _ = d.Out.(*os.File)
	if in == nil || out == nil || os.Getenv("TERM") == "dumb" {
		return nil, nil, false
	}
	return in, out, isTerminal(in) && isTerminal(out)
}

// menuTUI is `nsonline config` on a terminal. errNoRaw means the terminal
// refused raw mode, and the caller falls back to the line menu.
func menuTUI(d Deps, in, out *os.File) error {
	store := settings.NewStore(d.DataDir)
	draft := store.Load()

	sc := &screen{in: in, out: out}
	if err := sc.open(); err != nil {
		return errNoRaw
	}
	defer sc.close()

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	defer func() { signal.Stop(sig); close(sig) }()
	go func() {
		if _, ok := <-sig; ok {
			sc.close()
			fmt.Fprintln(out, i18n.T("cli.config.canceled"))
			os.Exit(1)
		}
	}()

	u := &tui{
		in:     in,
		out:    out,
		screen: sc,
		head:   newHeader(i18n.T("cli.config.header"), i18n.T("cli.config.subtitle"), i18n.T("cli.config.keys")),
		mode:   detectColor(os.Getenv),
		size:   func() (int, int) { return termSize(out) },
	}
	s, err := u.run(tuiState{orig: draft, draft: draft})
	sc.close()
	if err != nil {
		return err
	}

	t := newTerm(in, out)
	if s.action == actCancel {
		t.say("cli.config.canceled")
		return ErrCanceledSaid
	}
	if err := store.Save(s.draft); err != nil {
		return err
	}
	t.say("cli.config.saved")
	return nil
}
