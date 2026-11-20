package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"runtime"
	"time"

	"nsonline/internal/discord"
	"nsonline/internal/lockfile"
	"nsonline/internal/modules/setup"
	"nsonline/internal/sidecar"
	"nsonline/shared/i18n"
)

func defaultDataDir() string {
	home, _ := os.UserHomeDir()
	dir := setup.DataDir(runtime.GOOS, home, os.Getenv)
	for _, old := range setup.LegacyDataDirs(runtime.GOOS, home, os.Getenv) {
		if moved, _ := setup.MigrateDataDir(dir, old); moved {
			break
		}
	}
	return dir
}

func dataDirFlag(name string) (*flag.FlagSet, *string) {
	fs := flag.NewFlagSet(name, flag.ExitOnError)
	return fs, fs.String("data-dir", defaultDataDir(), i18n.T("cli.flag.dataDirCli"))
}

// checkUnlocked refuses to run while `nsonline app` uses the same data dir:
// both would write settings.json and the token files at the same time.
func checkUnlocked(stderr io.Writer, dir string) bool {
	if pid := lockfile.Holder(dir); pid != 0 {
		fmt.Fprintln(stderr, i18n.T("cli.setup.locked", i18n.Args{"pid": pid}))
		return false
	}
	return true
}

func showTestActivity() error {
	id := discordApps().ForPlatform(0)
	c, err := discord.Connect(id)
	if err != nil {
		return err
	}
	defer c.Close()

	if err := c.SetActivity(sidecar.TestActivity()); err != nil {
		return err
	}
	time.Sleep(5 * time.Second)
	return c.SetActivity(nil)
}

func setupDeps(dir string, browser bool) setup.Deps {
	d := setup.Deps{In: os.Stdin, Out: os.Stdout, DataDir: dir, Znca: zncaConfigFromEnv()}
	if browser {
		d.OpenBrowser = openBrowser
	}
	if discordApps().Configured() {
		d.TestDiscord = showTestActivity
	}
	return d
}

func exitOn(err error) {
	switch {
	case err == nil:
	case errors.Is(err, setup.ErrCanceledSaid):
		os.Exit(1)
	case errors.Is(err, setup.ErrCanceled):
		fmt.Fprintln(os.Stderr, i18n.T("cli.setup.canceled"))
		os.Exit(1)
	default:
		fmt.Fprintln(os.Stderr, "nsonline:", err)
		os.Exit(1)
	}
}

func runSetup(args []string) {
	fs, dir := dataDirFlag("setup")
	noBrowser := fs.Bool("no-browser", false, i18n.T("cli.flag.noBrowser"))
	fs.Parse(args)

	if err := os.MkdirAll(*dir, 0o700); err != nil {
		exitOn(err)
	}
	if !checkUnlocked(os.Stderr, *dir) {
		os.Exit(1)
	}
	exitOn(setup.Wizard(setupDeps(*dir, !*noBrowser)))
}
