package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"nsonline/internal/env"
	api "nsonline/internal/http"
	"nsonline/internal/presence"
	"nsonline/internal/providers"
	"nsonline/internal/providers/nswitch"
	"nsonline/internal/providers/nswitch/client"
	"nsonline/internal/secrets"
	"nsonline/internal/version"
	"nsonline/shared/i18n"
)

// baseConfig is GET /api/config. maskDiscord: app mode, where the IDs are embedded in the binary.
func baseConfig(maskDiscord bool) presence.Config {
	auth := "none"
	switch {
	case secrets.Get("NXAPI_ZNCA_API_CLIENT_SECRET") != "":
		auth = "client_secret"
	case secrets.Get("NXAPI_ZNCA_API_SHARED_SECRET") != "":
		auth = "shared_secret"
	}

	discordID := func(key string) string {
		if maskDiscord {
			return api.MaskID(secrets.Get(key))
		}
		return secrets.Get(key)
	}

	return presence.Config{
		DiscordSwitch2ID:  discordID("DISCORD_CLIENT_ID_SWITCH2"),
		DiscordSwitchID:   discordID("DISCORD_CLIENT_ID_SWITCH"),
		DiscordDefaultID:  discordID("DISCORD_CLIENT_ID"),
		ZncaClientID:      api.MaskID(secrets.Get("NXAPI_ZNCA_API_CLIENT_ID")),
		ZncaAuth:          auth,
		ZncaHasSecret:     auth != "none",
		Contact:           secrets.Get("NSONLINE_CONTACT"),
		AppVersion:        client.AppVersion(),
		Version:           version.Version,
		DiscordConfigured: discordApps().Configured(),
		ZncaConfigured:    secrets.Get("NXAPI_ZNCA_API_CLIENT_ID") != "",
	}
}

func serveConfig(target string, interval, idle time.Duration) presence.Config {
	c := baseConfig(false)
	c.WatchTarget = target
	c.IntervalSeconds, c.IdleIntervalSeconds = int(interval.Seconds()), int(idle.Seconds())
	return c
}

// openMainSession returns nil when the main account is not logged in: the app then lists the observer's friends.
func openMainSession(path string, verbose bool) *nswitch.Session {
	if st, err := nswitch.LoadStore(path); err != nil || st.SessionToken == "" {
		log.Printf("main account not logged in (%s): the app lists the observer's friends. "+
			"To list yours: ./nsonline login -auth-file %s", path, path)
		return nil
	}
	return openCoralSession(path, verbose)
}

func runServe(args []string) {
	fs, cf := nintendoFlags("serve")
	wf := addWatchFlags(fs)
	addr := fs.String("addr", env.Or("NSO_API_ADDR", "127.0.0.1:7878"), i18n.T("cli.flag.addr"))
	discordOff := fs.Bool("discord-off", false, i18n.T("cli.flag.discordOff"))
	mainAuth := fs.String("main-auth-file", env.Or("NSO_MAIN_AUTH_FILE", "nso-auth-main.json"), i18n.T("cli.flag.mainAuthFile"))
	friendsEvery := fs.Duration("friends-interval", presence.MinInterval, i18n.T("cli.flag.friendsInterval"))
	fs.Parse(args)

	host, port, err := net.SplitHostPort(*addr)
	if err != nil || !net.ParseIP(host).IsLoopback() {
		log.Fatal(i18n.T("cli.serve.addrNotLoopback", i18n.Args{"addr": fmt.Sprintf("%q", *addr)}))
	}
	if nswitch.SamePath(*cf.authFile, *mainAuth) {
		log.Fatal(i18n.T("cli.serve.sameAuthFile", i18n.Args{"file": *mainAuth}))
	}
	s := openCoralSession(*cf.authFile, *cf.verbose)
	main := openMainSession(*mainAuth, *cf.verbose)

	link := &presence.DiscordLink{}
	interval, idle := wf.intervals()
	opts := presence.Options{
		FetchFriends: s.Friends,
		Tokens:       s.Store.Tokens,
		Sink:         link,
		Apps:         wf.apps(),
		Target:       *wf.target,
		Interval:     interval,
		Idle:         idle,
		Config:       serveConfig(*wf.target, interval, idle),
		Enabled:      !*discordOff,
		ShowIdle:     *wf.showIdle,
		FetchPlayLog: s.PlayLog,
	}
	if main != nil {
		opts.MainFriends = func() ([]providers.Friend, error) {
			friends, err := main.Friends()
			if err == nil {
				if _, ferr := main.EnsureFriendCode(); ferr != nil {
					log.Printf("main account friend code: %v", ferr)
				}
			}
			return friends, err
		}
		opts.MainAccount = main.Store.Observer
		opts.MainInterval = presence.AtLeast(*friendsEvery, presence.MinInterval)
	}
	svc := presence.New(opts)

	srv := api.NewServer(*addr, api.Handler(svc, port))
	ln, err := net.Listen("tcp", *addr)
	if err != nil {
		log.Fatal(err)
	}
	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("api: %v", err)
		}
	}()
	log.Printf("API on http://%s · watching %q (every %s in game, %s otherwise). Ctrl+C to stop.", *addr, *wf.target, interval, idle)

	stop := stopSignal()
	err = svc.Run(stop)
	if err != nil {
		// fatal for the loop (e.g. outdated app version): keep the API up to show it
		log.Printf("presence loop stopped: %v", err)
		clearPresence(link)
		<-stop
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = srv.Shutdown(ctx)
	clearPresence(link)
	if err != nil {
		os.Exit(1)
	}
}
