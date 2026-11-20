//go:build !windows

package discord

import (
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"syscall"
)

// dial tries discord-ipc-0..9 in the usual temp dirs (macOS / Linux, incl. Flatpak & Snap).
func dial() (io.ReadWriteCloser, error) {
	var bases []string
	for _, env := range []string{"XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"} {
		if v := os.Getenv(env); v != "" {
			bases = append(bases, v)
		}
	}
	bases = append(bases, "/tmp")

	var dirs []string
	for _, b := range bases {
		dirs = append(dirs, b,
			filepath.Join(b, "app", "com.discordapp.Discord"), // Flatpak
			filepath.Join(b, "snap.discord"),                  // Snap
		)
	}

	var lastErr error
	for _, d := range dirs {
		for i := 0; i < 10; i++ {
			path := filepath.Join(d, fmt.Sprintf("discord-ipc-%d", i))
			if !ownedByMe(path) {
				continue // someone else's socket (e.g. squatting world-writable /tmp)
			}
			conn, err := net.Dial("unix", path)
			if err == nil {
				return conn, nil
			}
			lastErr = err
		}
	}
	return nil, lastErr
}

func ownedByMe(path string) bool {
	fi, err := os.Lstat(path)
	if err != nil {
		return false
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	return !ok || int(st.Uid) == os.Getuid()
}
