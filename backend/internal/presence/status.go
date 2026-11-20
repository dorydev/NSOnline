package presence

import (
	"nsonline/internal/discord"
	"nsonline/internal/providers"
)

const (
	PresenceOffline = "offline"
	PresenceOnline  = "online"
	PresencePlaying = "playing"
	PresenceIdle    = "idle"
)

type PresenceGame struct {
	Name           string `json:"name"`
	ImageURI       string `json:"imageUri"`
	ShopURI        string `json:"shopUri"`
	TotalPlayTime  int    `json:"totalPlayTime"`
	SysDescription string `json:"sysDescription"`
}

type PresenceStatus struct {
	State      string        `json:"state"`
	Game       *PresenceGame `json:"game"`
	StartedAt  int64         `json:"startedAt"`
	Platform   int           `json:"platform"`
	DiscordApp string        `json:"discordApp"`
}

func OfflinePresence() PresenceStatus {
	return PresenceStatus{State: PresenceOffline, DiscordApp: "default"}
}

// appName names the Discord app behind clientID: the console's asset key ("switch2"), else "default".
func appName(clientID string, apps DiscordApps) string {
	if clientID == "" {
		return "default"
	}
	for _, id := range apps.platforms() {
		if apps.ByPlatform[id] == clientID {
			return providers.PlatformOf(id).Asset
		}
	}
	return "default"
}

func presenceStatus(p providers.Presence, a *discord.Activity, clientID string, apps DiscordApps) PresenceStatus {
	st := PresenceStatus{State: PresenceOffline, Platform: p.Platform, DiscordApp: appName(clientID, apps)}

	switch {
	case a == nil && p.ConsoleOn():
		st.State = PresenceOnline
	case a == nil:
	case IsIdle(a):
		st.State = PresenceIdle
	default:
		st.State = PresencePlaying
		g := p.Game
		st.Game = &PresenceGame{Name: g.Name, ImageURI: g.ImageURI, ShopURI: g.ShopURI, TotalPlayTime: g.TotalPlayTime, SysDescription: g.SysDescription}
		if a.Timestamps != nil {
			st.StartedAt = a.Timestamps.Start
		}
	}
	return st
}
