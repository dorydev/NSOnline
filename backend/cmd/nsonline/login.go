package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"runtime"
	"strings"

	"nsonline/internal/env"
	"nsonline/internal/providers"
	"nsonline/internal/providers/nswitch"
	"nsonline/internal/providers/nswitch/auth"
	"nsonline/internal/providers/nswitch/client"
	"nsonline/internal/providers/nswitch/coral"
	"nsonline/internal/providers/nswitch/znca"
	"nsonline/internal/secrets"
	"nsonline/shared/i18n"
)

var stdin = bufio.NewReader(os.Stdin)

func readLine() string {
	line, err := stdin.ReadString('\n')
	if err != nil && line == "" {
		log.Fatal(err)
	}
	return strings.TrimSpace(line)
}

func printJSON(raw []byte) {
	var buf bytes.Buffer
	if err := json.Indent(&buf, raw, "", "  "); err != nil {
		os.Stdout.Write(raw)
		return
	}
	fmt.Println(buf.String())
}

func openBrowser(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", url)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	_ = cmd.Start()
}

func zncaConfigFromEnv() znca.Config {
	return znca.Config{
		BaseURL:      env.Get("ZNCA_API_URL"),
		TokenURL:     env.Get("NXAPI_AUTH_TOKEN_URL"),
		Issuer:       env.Get("NXAPI_AUTH_ISSUER"),
		ClientID:     secrets.Get("NXAPI_ZNCA_API_CLIENT_ID"),
		ClientSecret: secrets.Get("NXAPI_ZNCA_API_CLIENT_SECRET"),
		SharedSecret: secrets.Get("NXAPI_ZNCA_API_SHARED_SECRET"),
		Contact:      secrets.Get("NSONLINE_CONTACT"),
	}
}

type commonFlags struct {
	verbose  *bool
	authFile *string
}

func nintendoFlags(name string) (*flag.FlagSet, commonFlags) {
	fs := flag.NewFlagSet(name, flag.ExitOnError)
	return fs, commonFlags{
		verbose:  fs.Bool("v", false, i18n.T("cli.flag.verbose")),
		authFile: fs.String("auth-file", env.Or("NSO_AUTH_FILE", "nso-auth.json"), i18n.T("cli.flag.authFile")),
	}
}

func openSession(path string, verbose bool) *nswitch.Session {
	st, err := nswitch.LoadStore(path)
	if err != nil {
		log.Fatal(err)
	}
	return &nswitch.Session{Store: st, Client: client.New(verbose)}
}

// ensureThirdPartyAck asks once before any data goes to the znca API: its terms require it.
func ensureThirdPartyAck(st *nswitch.Store, zncaURL string) bool {
	if st.AckedFor(zncaURL) {
		return true
	}

	fmt.Print(i18n.T("cli.consent.prompt", i18n.Args{"url": zncaURL, "yes": i18n.T("cli.consent.yes")}) + " ")
	if a := strings.ToLower(readLine()); a != "yes" && a != strings.ToLower(i18n.T("cli.consent.yes")) {
		return false
	}

	st.AckThirdParty(zncaURL)
	return st.Save() == nil
}

func openCoralSession(path string, verbose bool) *nswitch.Session {
	s := openSession(path, verbose)

	z, err := nswitch.NewZnca(s.Client, s.Store, zncaConfigFromEnv())
	if err != nil {
		log.Fatal(err)
	}
	if !ensureThirdPartyAck(s.Store, z.BaseURL) {
		log.Fatal(i18n.T("cli.consent.aborted"))
	}

	s.Znca = z
	return s
}

func runLogin(args []string) {
	fs, cf := nintendoFlags("login")
	fs.Parse(args)
	s := openSession(*cf.authFile, *cf.verbose)

	login, err := auth.NewLoginRequest()
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(i18n.T("cli.login.instructions", i18n.Args{"url": login.URL, "prefix": auth.RedirectURI}))
	openBrowser(login.URL)

	fmt.Print("> ")
	code, err := login.ParseRedirect(readLine())
	if err != nil {
		log.Fatal(err)
	}
	token, err := auth.ExchangeSessionToken(s.Client, login, code)
	if err != nil {
		log.Fatal(err)
	}
	if err := s.Store.ResetSession(token); err != nil {
		log.Fatal(err)
	}
	fmt.Println(i18n.T("cli.login.saved", i18n.Args{"file": *cf.authFile}))
}

func runMe(args []string) {
	fs, cf := nintendoFlags("me")
	raw := fs.Bool("raw", false, i18n.T("cli.flag.meRaw"))
	fs.Parse(args)
	s := openSession(*cf.authFile, *cf.verbose)

	acct, err := s.EnsureAccount()
	if err != nil {
		log.Fatal(err)
	}
	user, err := auth.Me(s.Client, acct.AccessToken)
	if err != nil {
		log.Fatal(err)
	}

	if *raw {
		printJSON(user.Raw)
		return
	}
	fmt.Println(i18n.T("cli.me.summary", i18n.Args{"id": user.ID, "nickname": user.Nickname, "country": user.Country, "language": user.Language}))
}

func printFriends(friends []providers.Friend) {
	fmt.Println(i18n.T("cli.friends.count", i18n.Args{"count": len(friends)}))
	fmt.Printf("  %-16s  %-20s  %-9s  %s\n", "NSA ID", i18n.T("cli.friends.colName"), i18n.T("cli.friends.colState"), i18n.T("cli.friends.colGame"))
	for _, f := range friends {
		fmt.Printf("  %-16s  %-20s  %-9s  %s\n", f.NsaID, f.Name, f.Presence.State, f.Presence.Game.Name)
	}
}

func runFriends(args []string) {
	fs, cf := nintendoFlags("friends")
	raw := fs.Bool("raw", false, i18n.T("cli.flag.friendsRaw"))
	fs.Parse(args)
	s := openCoralSession(*cf.authFile, *cf.verbose)

	body, err := s.FriendsRaw()
	if err != nil {
		log.Fatal(err)
	}
	if *raw {
		printJSON(body)
		return
	}

	friends, err := coral.ParseFriends(body)
	if err != nil {
		log.Printf("cannot summarise (%v), raw JSON:", err)
		printJSON(body)
		return
	}
	printFriends(friends)
}
