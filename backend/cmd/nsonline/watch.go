package main

import (
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"nsonline/internal/env"
	"nsonline/internal/presence"
	"nsonline/internal/providers"
	"nsonline/internal/secrets"
	"nsonline/shared/i18n"
)

type watchFlags struct {
	target, clientID *string
	interval, idle   *time.Duration
	showIdle         *bool
}

func addWatchFlags(fs *flag.FlagSet) watchFlags {
	return watchFlags{
		target:   fs.String("friend", env.Get("NSO_WATCH_FRIEND"), i18n.T("cli.flag.friend")),
		interval: fs.Duration("interval", presence.MinInterval, i18n.T("cli.flag.interval")),
		idle:     fs.Duration("idle-interval", presence.MinInterval, i18n.T("cli.flag.idleInterval")),
		clientID: fs.String("client-id", secrets.Get("DISCORD_CLIENT_ID"), i18n.T("cli.flag.clientIdDefault")),
		showIdle: fs.Bool("show-idle", false, i18n.T("cli.flag.showIdle")),
	}
}

func (w watchFlags) apps() presence.DiscordApps { return presence.AppsFromProviders(*w.clientID) }

func (w watchFlags) intervals() (inGame, idle time.Duration) {
	return presence.AtLeast(*w.interval, presence.MinInterval), presence.AtLeast(*w.idle, presence.MinInterval)
}

func discordApps() presence.DiscordApps {
	return presence.AppsFromProviders(secrets.Get("DISCORD_CLIENT_ID"))
}

func clearPresence(link *presence.DiscordLink) {
	if link.Connected() && link.Set("", nil) == nil {
		log.Println("presence cleared")
	}
	link.Close()
}

func stopSignal() <-chan struct{} {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)

	stop := make(chan struct{})
	go func() { <-sig; close(stop) }()
	return stop
}

func runWatch(args []string) {
	fs, cf := nintendoFlags("watch")
	wf := addWatchFlags(fs)
	fs.Parse(args)

	apps := wf.apps()
	if *wf.target == "" {
		log.Fatal(i18n.T("cli.watch.missingFriend"))
	}
	if !apps.Configured() {
		log.Fatal(i18n.T("cli.watch.missingDiscordID"))
	}
	s := openCoralSession(*cf.authFile, *cf.verbose)

	link := &presence.DiscordLink{}
	interval, idle := wf.intervals()
	w := &presence.Watcher{
		Fetch:    func() (providers.Presence, string, error) { return s.Presence(*wf.target) },
		Sink:     link,
		Apps:     apps,
		Interval: interval,
		Idle:     idle,
		Now:      time.Now,
		ShowIdle: func() bool { return *wf.showIdle },
	}
	log.Printf("watching %q (every %s in game, %s otherwise). Ctrl+C to stop.", *wf.target, w.Interval, w.Idle)

	err := w.Run(stopSignal())
	clearPresence(link)
	if err != nil {
		log.Printf("stopped: %v", err)
		os.Exit(1)
	}
}
