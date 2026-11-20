package presence

import (
	"fmt"

	"nsonline/internal/discord"
)

// DiscordLink keeps one IPC connection and switches Discord app when the console changes.
type DiscordLink struct {
	clientID string
	c        *discord.Client
}

func (d *DiscordLink) Set(clientID string, a *discord.Activity) error {
	if clientID != "" && clientID != d.clientID {
		d.Close()
		d.clientID = clientID
	}

	if d.c == nil {
		if a == nil {
			return nil
		}
		c, err := discord.Connect(d.clientID)
		if err != nil {
			return err
		}
		d.c = c
	}

	if err := d.c.SetActivity(a); err != nil {
		d.Close()
		return fmt.Errorf("set activity: %w", err)
	}
	return nil
}

func (d *DiscordLink) Close() {
	if d.c != nil {
		d.c.Close()
		d.c = nil
	}
}

func (d *DiscordLink) Connected() bool { return d.c != nil }
