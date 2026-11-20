package setup

import (
	"fmt"
	"strings"

	"nsonline/internal/modules/settings"
	"nsonline/shared/i18n"
)

var languages = []struct{ code, name string }{{"en", "English"}, {"fr", "Français"}}

func onOff(on bool) string {
	if on {
		return i18n.T("cli.config.on")
	}
	return i18n.T("cli.config.off")
}

func languageName(code string) string {
	for _, l := range languages {
		if l.code == code {
			return l.name
		}
	}
	return i18n.T("cli.config.languageDefault")
}

func settingRows(s settings.Settings) [][2]string {
	target := s.WatchTarget
	if target == "" {
		target = i18n.T("cli.config.none")
	}
	return [][2]string{
		{i18n.T("cli.config.target"), target},
		{i18n.T("cli.config.interval"), fmt.Sprintf("%d s", s.IntervalSeconds)},
		{i18n.T("cli.config.idleInterval"), fmt.Sprintf("%d s", s.IdleIntervalSeconds)},
		{i18n.T("cli.config.friendsInterval"), fmt.Sprintf("%d s", s.FriendsIntervalSeconds)},
		{i18n.T("cli.config.showIdle"), onOff(s.ShowIdle)},
		{i18n.T("cli.config.discord"), onOff(s.DiscordEnabled)},
		{i18n.T("cli.config.language"), languageName(s.Language)},
	}
}

func printSettings(t *term, s settings.Settings, numbered bool) {
	for i, r := range settingRows(s) {
		if numbered {
			fmt.Fprintf(t.out, "  %d) %-26s %s\n", i+1, r[0], r[1])
		} else {
			fmt.Fprintf(t.out, "  %-29s %s\n", r[0], r[1])
		}
	}
}

func (t *term) language(current string) (string, error) {
	t.say("cli.config.languagePick")
	def := 0
	for i, l := range languages {
		fmt.Fprintf(t.out, "  %d) %s\n", i+1, l.name)
		if l.code == current {
			def = i + 1
		}
	}
	if def == 0 {
		def = 1
	}

	n, err := t.number(i18n.T("cli.prompt.choice", i18n.Args{"value": def}), len(languages), def, false)
	if err != nil {
		return current, err
	}
	return languages[n-1].code, nil
}

func (t *term) editTarget(s *settings.Settings) error {
	for {
		v, err := t.line(i18n.T("cli.config.targetAsk", i18n.Args{"current": s.WatchTarget}))
		if err != nil {
			return err
		}
		switch v {
		case "":
			return nil
		case "-":
			v = ""
		}

		next := *s
		next.WatchTarget = v
		if err := next.Validate(); err != nil {
			t.say("cli.setup.invalid", i18n.Args{"error": err.Error()})
			continue
		}
		*s = next
		return nil
	}
}

func (t *term) edit(s *settings.Settings, n int) error {
	var err error
	switch n {
	case 1:
		err = t.editTarget(s)
	case 2:
		s.IntervalSeconds, err = t.seconds(i18n.T("cli.config.interval"), s.IntervalSeconds, settings.MinSeconds, settings.MaxSeconds)
	case 3:
		s.IdleIntervalSeconds, err = t.seconds(i18n.T("cli.config.idleInterval"), s.IdleIntervalSeconds, settings.MinSeconds, settings.MaxSeconds)
	case 4:
		s.FriendsIntervalSeconds, err = t.seconds(i18n.T("cli.config.friendsInterval"), s.FriendsIntervalSeconds, settings.MinSeconds, settings.MaxSeconds)
	case 5:
		s.ShowIdle = !s.ShowIdle
	case 6:
		s.DiscordEnabled = !s.DiscordEnabled
	case 7:
		s.Language, err = t.language(s.Language)
	}
	return err
}

// Menu runs `nsonline config`. Edits stay in a draft: only Save writes
// settings.json (keeping settings.json.bak). Cancel, EOF or Ctrl+C write nothing.
// On a terminal it is the arrow-key menu, elsewhere a numbered line menu.
func Menu(d Deps) error {
	if in, out, ok := interactive(d); ok {
		if err := menuTUI(d, in, out); err != errNoRaw {
			return err
		}
	}

	t := newTerm(d.In, d.Out)
	store := settings.NewStore(d.DataDir)
	draft := store.Load()

	newHeader(i18n.T("cli.config.header"), i18n.T("cli.config.subtitle"), "").write(t.out, noColor)
	for {
		fmt.Fprintln(t.out)
		printSettings(t, draft, true)
		t.say("cli.config.actions")

		a, err := t.line(">")
		if err != nil {
			return err
		}

		switch {
		case isAnswer(a, "cli.config.saveWords"):
			if err := store.Save(draft); err != nil {
				return err
			}
			t.say("cli.config.saved")
			return nil
		case isAnswer(a, "cli.config.cancelWords"):
			t.say("cli.config.canceled")
			return ErrCanceledSaid
		}

		var n int
		if _, err := fmt.Sscan(strings.TrimSpace(a), &n); err != nil || n < 1 || n > 7 {
			t.say("cli.config.invalidChoice")
			continue
		}
		if err := t.edit(&draft, n); err != nil {
			return err
		}
	}
}
