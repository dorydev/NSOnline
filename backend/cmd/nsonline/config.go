package main

import (
	"os"

	"nsonline/internal/modules/setup"
)

func runConfig(args []string) {
	fs, dir := dataDirFlag("config")
	fs.Parse(args)

	if err := os.MkdirAll(*dir, 0o700); err != nil {
		exitOn(err)
	}
	if !checkUnlocked(os.Stderr, *dir) {
		os.Exit(1)
	}
	exitOn(setup.Menu(setupDeps(*dir, false)))
}
