package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"nsonline/internal/env"
	"nsonline/internal/modules/settings"
	"nsonline/internal/providers"
	_ "nsonline/internal/providers/n3ds"
	"nsonline/internal/providers/nswitch"
	"nsonline/internal/providers/nswitch/client"
	_ "nsonline/internal/providers/wiiu"
	"nsonline/internal/secrets"
	"nsonline/internal/version"
	"nsonline/shared/i18n"
)

func usage() string { return i18n.T("cli.usage", i18n.Args{"version": version.Version}) }

// extractLang removes --lang X / --lang=X (one or two dashes) from anywhere in args.
func extractLang(args []string) (string, []string) {
	lang := ""
	out := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "--lang" || a == "-lang":
			if i+1 < len(args) {
				lang = args[i+1]
				i++
			}
		case strings.HasPrefix(a, "--lang=") || strings.HasPrefix(a, "-lang="):
			lang = a[strings.IndexByte(a, '=')+1:]
		default:
			out = append(out, a)
		}
	}
	return lang, out
}

func savedLanguage(args []string) string {
	dir := defaultDataDir()
	for i, a := range args {
		switch {
		case (a == "--data-dir" || a == "-data-dir") && i+1 < len(args):
			dir = args[i+1]
		case strings.HasPrefix(a, "--data-dir=") || strings.HasPrefix(a, "-data-dir="):
			dir = a[strings.IndexByte(a, '=')+1:]
		}
	}

	if _, err := os.Stat(filepath.Join(dir, settings.FileName)); err != nil {
		return ""
	}
	return settings.NewStore(dir).Load().Language
}

func main() {
	env.Load(".env")

	lang, argv := extractLang(os.Args[1:])
	if lang == "" {
		lang = os.Getenv(i18n.EnvVar)
	}
	if lang == "" && len(argv) > 0 && (argv[0] == "setup" || argv[0] == "config") {
		lang = savedLanguage(argv[1:])
	}
	i18n.SetLocale(lang)

	if fi, err := os.Stat(".env"); err == nil && fi.Mode().Perm()&0o077 != 0 {
		fmt.Fprintln(os.Stderr, i18n.T("cli.envPermsWarning"))
	}
	client.SetAppVersion(secrets.Get("NSO_APP_VERSION"))
	providers.Register(nswitch.New(zncaConfigFromEnv(), false))

	if len(argv) < 1 {
		fmt.Fprint(os.Stderr, usage())
		os.Exit(2)
	}

	cmd, args := argv[0], argv[1:]
	switch cmd {
	case "login":
		runLogin(args)
	case "me":
		runMe(args)
	case "friends":
		runFriends(args)
	case "watch":
		runWatch(args)
	case "serve":
		runServe(args)
	case "app":
		runApp(args)
	case "setup":
		runSetup(args)
	case "config":
		runConfig(args)
	case "rpc":
		runRPC(args)
	case "-h", "--help", "help":
		fmt.Print(usage())
	case "version", "--version", "-version":
		fmt.Println(version.Version)
	default:
		fmt.Fprint(os.Stderr, i18n.T("cli.unknownCommand", i18n.Args{"command": fmt.Sprintf("%q", cmd)})+"\n\n"+usage())
		os.Exit(2)
	}
}
