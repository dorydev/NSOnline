package main

import (
	"flag"
	"log"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"nsonline/internal/discord"
	"nsonline/internal/secrets"
	"nsonline/shared/i18n"
)

func runRPC(args []string) {
	fs := flag.NewFlagSet("rpc", flag.ExitOnError)
	clientID := fs.String("client-id", secrets.Get("DISCORD_CLIENT_ID"), i18n.T("cli.flag.clientId"))
	details := fs.String("details", i18n.T("cli.rpc.defaultDetails"), i18n.T("cli.flag.details"))
	state := fs.String("state", i18n.T("cli.rpc.defaultState"), i18n.T("cli.flag.state"))
	start := fs.String("start", "now", i18n.T("cli.flag.start"))
	end := fs.Int64("end", 0, i18n.T("cli.flag.end"))
	largeImage := fs.String("large-image", "", i18n.T("cli.flag.largeImage"))
	largeText := fs.String("large-text", "", i18n.T("cli.flag.largeText"))
	smallImage := fs.String("small-image", "", i18n.T("cli.flag.smallImage"))
	smallText := fs.String("small-text", "", i18n.T("cli.flag.smallText"))
	partyID := fs.String("party-id", "", i18n.T("cli.flag.partyId"))
	partySize := fs.Int("party-size", 0, i18n.T("cli.flag.partySize"))
	partyMax := fs.Int("party-max", 0, i18n.T("cli.flag.partyMax"))
	buttonLabel := fs.String("button-label", "", i18n.T("cli.flag.buttonLabel"))
	buttonURL := fs.String("button-url", "", i18n.T("cli.flag.buttonUrl"))
	fs.Parse(args)

	if *clientID == "" {
		log.Fatal(i18n.T("cli.rpc.missingClientID"))
	}

	var startTS int64
	switch *start {
	case "":
	case "now":
		startTS = time.Now().Unix()
	default:
		v, err := strconv.ParseInt(*start, 10, 64)
		if err != nil {
			log.Fatal(i18n.T("cli.rpc.invalidStart", i18n.Args{"value": strconv.Quote(*start)}))
		}
		startTS = v
	}
	if *partySize > 0 && *partyMax < *partySize {
		log.Fatal(i18n.T("cli.rpc.partyMax"))
	}

	client, err := discord.Connect(*clientID)
	if err != nil {
		log.Fatal(err)
	}
	defer client.Close()
	log.Printf("connected as %s (%s)", client.User.Username, client.User.ID)

	activity := &discord.Activity{
		Type:    discord.Playing,
		Details: *details,
		State:   *state,
	}
	if startTS != 0 || *end != 0 {
		activity.Timestamps = &discord.Timestamps{Start: startTS, End: *end}
	}
	if *largeImage != "" || *smallImage != "" {
		activity.Assets = &discord.Assets{
			LargeImage: *largeImage, LargeText: *largeText,
			SmallImage: *smallImage, SmallText: *smallText,
		}
	}
	if *partyID != "" || *partySize > 0 {
		activity.Party = &discord.Party{ID: *partyID}
		if *partySize > 0 {
			activity.Party.Size = []int{*partySize, *partyMax}
		}
	}
	if *buttonLabel != "" && *buttonURL != "" {
		activity.Buttons = []discord.Button{{Label: *buttonLabel, URL: *buttonURL}}
	}

	if err := client.SetActivity(activity); err != nil {
		log.Fatal(err)
	}
	log.Println("presence set, check your Discord profile. Ctrl+C to stop.")

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	<-sig

	if err := client.SetActivity(nil); err != nil {
		log.Printf("clear activity: %v", err)
	}
	log.Println("presence cleared, bye")
}
