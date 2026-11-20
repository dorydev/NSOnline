// Package atomicfile writes through a temp file, fsync and rename: a crash never leaves half a file.
package atomicfile

import (
	"os"
	"path/filepath"
	"runtime"
)

func Write(path string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*.tmp") // created 0600
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name) // no-op after a successful rename
	if perm != 0o600 {
		if err := tmp.Chmod(perm); err != nil && runtime.GOOS != "windows" {
			tmp.Close()
			return err
		}
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Sync(); err != nil { // on disk before the rename replaces the old file
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(name, path); err != nil {
		return err
	}
	syncDir(dir)
	return nil
}

// syncDir: directories cannot be opened for sync on Windows, best effort.
func syncDir(dir string) {
	if runtime.GOOS == "windows" {
		return
	}
	if d, err := os.Open(dir); err == nil {
		_ = d.Sync()
		d.Close()
	}
}
