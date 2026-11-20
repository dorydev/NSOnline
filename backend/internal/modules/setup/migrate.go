package setup

import (
	"io"
	"os"
	"path/filepath"
)

// LegacyDataDirs are the folders of older versions, newest first: before the
// dev.dorydev.nsonline → dev.nsonline.app rename, then before nso_rpc → nsonline.
func LegacyDataDirs(goos, home string, getenv func(string) string) []string {
	switch goos {
	case "darwin":
		base := filepath.Join(home, "Library", "Application Support")
		return []string{filepath.Join(base, "dev.dorydev.nsonline"), filepath.Join(base, "dev.dorydev.nsoRpc")}
	case "windows":
		appData := getenv("APPDATA")
		if appData == "" {
			appData = filepath.Join(home, "AppData", "Roaming")
		}
		return []string{filepath.Join(appData, "dorydev", "nsonline"), filepath.Join(appData, "dorydev", "nso_rpc")}
	}

	data := getenv("XDG_DATA_HOME")
	if data == "" {
		data = filepath.Join(home, ".local", "share")
	}
	return []string{filepath.Join(data, "dev.dorydev.nsonline"), filepath.Join(data, "dev.dorydev.nso_rpc")}
}

func copyFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()

	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode.Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

var keyFiles = []string{"settings.json", "nso-auth.json", "app_prefs.json"}

func hasData(dir string) bool {
	for _, f := range keyFiles {
		if _, err := os.Stat(filepath.Join(dir, f)); err == nil {
			return true
		}
	}
	return false
}

// MigrateDataDir copies the old folder into the new one while the new one has
// no data yet (the app creates the folder itself). Nothing is overwritten and
// the old folder is left untouched.
func MigrateDataDir(newDir, oldDir string) (bool, error) {
	if hasData(newDir) {
		return false, nil
	}
	if fi, err := os.Stat(oldDir); err != nil || !fi.IsDir() {
		return false, nil
	}

	err := filepath.Walk(oldDir, func(path string, fi os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(oldDir, path)
		target := filepath.Join(newDir, rel)

		if fi.IsDir() {
			return os.MkdirAll(target, 0o700)
		}
		if !fi.Mode().IsRegular() || fi.Name() == "backend.lock" {
			return nil
		}
		if _, err := os.Stat(target); err == nil {
			return nil
		}
		return copyFile(path, target, fi.Mode())
	})
	if err != nil {
		return false, err
	}
	return true, nil
}
