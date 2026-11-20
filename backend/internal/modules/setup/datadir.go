package setup

import "path/filepath"

// DataDir is the desktop app's data dir, so the CLI and `nsonline app` share files.
func DataDir(goos, home string, getenv func(string) string) string {
	switch goos {
	case "darwin":
		return filepath.Join(home, "Library", "Application Support", "dev.nsonline.app")
	case "windows":
		appData := getenv("APPDATA")
		if appData == "" {
			appData = filepath.Join(home, "AppData", "Roaming")
		}
		return filepath.Join(appData, "nsonline", "nsonline")
	}

	data := getenv("XDG_DATA_HOME")
	if data == "" {
		data = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(data, "dev.nsonline.app")
}
