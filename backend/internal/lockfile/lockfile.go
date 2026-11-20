// Package lockfile marks a data dir as used by a running `nsonline app`, so
// `nsonline setup` and `config` don't write the same files at the same time.
package lockfile

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const Name = "backend.lock"

func path(dir string) string { return filepath.Join(dir, Name) }

// Write records pid and returns a func removing the file, if it is still ours.
func Write(dir string, pid int) (func(), error) {
	if err := os.WriteFile(path(dir), []byte(strconv.Itoa(pid)+"\n"), 0o600); err != nil {
		return func() {}, err
	}

	return func() {
		if owner, _ := read(dir); owner == pid {
			os.Remove(path(dir))
		}
	}, nil
}

func read(dir string) (int, error) {
	b, err := os.ReadFile(path(dir))
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(strings.TrimSpace(string(b)))
}

// Holder returns the pid of a live backend using dir, or 0. A stale file (dead pid) is ignored.
func Holder(dir string) int {
	pid, err := read(dir)
	if errors.Is(err, fs.ErrNotExist) || err != nil || pid <= 0 {
		return 0
	}
	if pid == os.Getpid() || !alive(pid) {
		return 0
	}
	return pid
}
