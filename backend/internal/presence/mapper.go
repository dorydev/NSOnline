package presence

import (
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"nsonline/internal/discord"
	"nsonline/internal/providers"
	"nsonline/shared/i18n"
)

// ResumeGrace: a game that comes back within this delay keeps its timer.
const ResumeGrace = 5 * time.Minute

func IdleDetails() string { return i18n.T("presence.idle") }

func ConsoleOn(p providers.Presence) bool { return p.ConsoleOn() }

// IsIdle checks the shape of the idle activity, not its text (which depends on the locale).
// Without assets, Discord shows the application's own icon.
func IsIdle(a *discord.Activity) bool {
	return a != nil && a.Timestamps == nil && len(a.Buttons) == 0 && a.Assets == nil && a.State == ""
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

type Player struct {
	Name       string
	AvatarURL  string
	FriendCode string
}

// label is the small image tooltip. Discord tooltips can't be selected, so the code is shown in full.
func (p Player) label() string {
	code := strings.TrimSpace(p.FriendCode)
	if code == "" {
		return truncate(p.Name, 128)
	}
	if !strings.HasPrefix(strings.ToUpper(code), "SW-") {
		code = "SW-" + code
	}
	return truncate(i18n.T("presence.playerWithCode", i18n.Args{"name": p.Name, "code": code}), 128)
}

func idleActivity() *discord.Activity {
	return &discord.Activity{Type: discord.Playing, Details: IdleDetails()}
}

func playTime(minutes int) string {
	if minutes <= 0 {
		return i18n.T("presence.firstTime")
	}

	h, m := minutes/60, minutes%60
	var parts []string
	if h > 0 {
		parts = append(parts, i18n.T("presence.hours", i18n.Args{"count": h}))
	}
	if m > 0 {
		parts = append(parts, i18n.T("presence.minutes", i18n.Args{"count": m}))
	}
	return i18n.T("presence.playedFor", i18n.Args{"duration": strings.Join(parts, " ")})
}

func stateLine(p providers.Presence) string {
	if d := strings.TrimSpace(p.Game.SysDescription); d != "" {
		return d
	}
	return playTime(p.Game.TotalPlayTime)
}

func activityKey(a *discord.Activity) string {
	if a == nil {
		return ""
	}

	key := a.Details + "|" + a.State
	if a.Assets != nil {
		key += "|" + a.Assets.LargeImage + "|" + a.Assets.LargeText + "|" + a.Assets.SmallImage + "|" + a.Assets.SmallText
	}
	if a.Timestamps != nil {
		key += fmt.Sprintf("|%d", a.Timestamps.Start)
	}
	for _, b := range a.Buttons {
		key += "|" + b.URL
	}
	return key
}

// Mapper turns a presence into a Discord activity and remembers when the game
// started, so the elapsed timer doesn't reset on every poll.
type Mapper struct {
	ShowIdle bool
	Player   Player

	game      string
	startedAt int64

	leftGame             string
	leftStart, leftAtSec int64
}

func (m *Mapper) Map(p providers.Presence, now time.Time) *discord.Activity {
	if !p.InGame() {
		if m.game != "" {
			m.leftGame, m.leftStart, m.leftAtSec = m.game, m.startedAt, now.Unix()
		}
		m.game, m.startedAt = "", 0

		if m.ShowIdle && p.ConsoleOn() {
			return idleActivity()
		}
		return nil
	}

	g := p.Game
	if g.Name != m.game {
		if m.game == "" && g.Name == m.leftGame && now.Unix()-m.leftAtSec <= int64(ResumeGrace/time.Second) {
			m.startedAt = m.leftStart
		} else {
			m.startedAt = p.UpdatedAt
			if m.startedAt == 0 || m.startedAt > now.Unix() {
				m.startedAt = now.Unix()
			}
		}
		m.game = g.Name
		m.leftGame, m.leftStart, m.leftAtSec = "", 0, 0
	}

	a := &discord.Activity{
		Type:              discord.Playing,
		Details:           g.Name,
		StatusDisplayType: discord.DisplayDetails,
		State:             stateLine(p),
		Timestamps:        &discord.Timestamps{Start: m.startedAt},
	}
	if strings.HasPrefix(g.ImageURI, "https://") {
		a.Assets = &discord.Assets{LargeImage: g.ImageURI, LargeText: g.Name}
	}
	if strings.HasPrefix(m.Player.AvatarURL, "https://") {
		if a.Assets == nil {
			a.Assets = &discord.Assets{}
		}
		a.Assets.SmallImage = m.Player.AvatarURL
		a.Assets.SmallText = m.Player.label()
	}
	if strings.HasPrefix(g.ShopURI, "https://") {
		a.Buttons = []discord.Button{{Label: i18n.T("presence.eshopButton"), URL: g.ShopURI}}
	}
	return a
}
