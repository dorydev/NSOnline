//go:build !(darwin || linux || freebsd || netbsd || openbsd || dragonfly || windows)

package setup

import (
	"errors"
	"os"
)

func isTerminal(*os.File) bool { return false }

func makeRaw(in, out *os.File) (func(), error) {
	return nil, errors.New("raw mode is not supported on this system")
}

func termSize(*os.File) (cols, rows int) { return 0, 0 }
