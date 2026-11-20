// Command i18ncheck validates the shared translation catalogs: same keys,
// same placeholders and same plural shape in every <locale>.json as in
// en.json. Usage: go run ./shared/i18n/cmd/i18ncheck [dir] (default: the
// catalogs embedded in the i18n package).
package main

import (
	"fmt"
	"io/fs"
	"os"

	"nsonline/shared/i18n"
)

func main() {
	var fsys fs.FS = i18n.Embedded()
	if len(os.Args) > 1 {
		fsys = os.DirFS(os.Args[1])
	}
	problems := i18n.Check(fsys)
	for _, p := range problems {
		fmt.Fprintln(os.Stderr, p)
	}
	if len(problems) > 0 {
		os.Exit(1)
	}
	fmt.Println("i18n: catalogs are consistent")
}
