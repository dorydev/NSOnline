package setup

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	"nsonline/shared/i18n"
)

var ErrCanceled = errors.New("setup canceled")

// ErrCanceledSaid is a cancel the user already saw a message for.
var ErrCanceledSaid = fmt.Errorf("%w", ErrCanceled)

type term struct {
	in  *bufio.Reader
	out io.Writer
}

func newTerm(in io.Reader, out io.Writer) *term {
	return &term{in: bufio.NewReader(in), out: out}
}

func (t *term) say(key string, args ...i18n.Args) {
	fmt.Fprintln(t.out, i18n.T(key, args...))
}

func (t *term) line(prompt string) (string, error) {
	fmt.Fprint(t.out, prompt+" ")

	s, err := t.in.ReadString('\n')
	if err != nil && s == "" {
		fmt.Fprintln(t.out)
		return "", ErrCanceled
	}
	return strings.TrimSpace(s), nil
}

func isAnswer(a string, keys ...string) bool {
	a = strings.ToLower(a)
	for _, k := range keys {
		for _, w := range strings.Split(i18n.T(k), "|") {
			if a == w {
				return true
			}
		}
	}
	return false
}

func (t *term) yesNo(prompt string, def bool) (bool, error) {
	hint := i18n.T("cli.prompt.yesNoDefaultNo")
	if def {
		hint = i18n.T("cli.prompt.yesNoDefaultYes")
	}

	for {
		a, err := t.line(prompt + " " + hint)
		if err != nil {
			return false, err
		}
		switch {
		case a == "":
			return def, nil
		case isAnswer(a, "cli.prompt.yesWords") || a == "y" || a == "yes":
			return true, nil
		case isAnswer(a, "cli.prompt.noWords") || a == "n" || a == "no":
			return false, nil
		}
		t.say("cli.prompt.invalidYesNo")
	}
}

// number reads 1..max, or 0 when allowZero. An empty answer gives def.
func (t *term) number(prompt string, max, def int, allowZero bool) (int, error) {
	low := 1
	if allowZero {
		low = 0
	}

	for {
		a, err := t.line(prompt)
		if err != nil {
			return 0, err
		}
		if a == "" && def >= low {
			return def, nil
		}
		if n, err := strconv.Atoi(a); err == nil && n >= low && n <= max {
			return n, nil
		}
		t.say("cli.prompt.invalidNumber", i18n.Args{"min": low, "max": max})
	}
}

func (t *term) seconds(label string, def, low, high int) (int, error) {
	for {
		a, err := t.line(i18n.T("cli.prompt.seconds", i18n.Args{"label": label, "value": def}))
		if err != nil {
			return 0, err
		}
		if a == "" {
			return def, nil
		}
		if n, err := strconv.Atoi(strings.TrimSuffix(a, "s")); err == nil && n >= low && n <= high {
			return n, nil
		}
		t.say("cli.prompt.invalidSeconds", i18n.Args{"min": low, "max": high})
	}
}
