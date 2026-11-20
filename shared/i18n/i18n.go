// Package i18n serves NSOnline's user-facing strings from the shared JSON
// catalogs next to this file (en.json, fr.json). The same files feed the
// Flutter app through app/tool/gen_i18n.dart.
//
// Format (see README.md): a flat JSON object of dotted keys. A value is either
// a string or a plural object {"one": "...", "other": "..."} chosen by the
// "count" argument. Placeholders are written {name}.
package i18n

import (
	"embed"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
)

// Default is the locale used when none (or an unknown one) is chosen.
const Default = "en"

// EnvVar selects the backend language (the desktop app sets it when it
// spawns `nsonline app`; the CLI also accepts --lang).
const EnvVar = "NSONLINE_LANG"

//go:embed *.json
var embedded embed.FS

// Args are the placeholder values of a message: {"name": "Lea", "count": 3}.
type Args map[string]any

// entry is one message: a plain string, or plural forms keyed by category.
type entry struct {
	text  string
	forms map[string]string
}

var (
	catalogs = mustLoad(embedded)
	current  atomic.Value // string
)

func init() { current.Store(Default) }

func Locales() []string {
	out := make([]string, 0, len(catalogs))
	for l := range catalogs {
		out = append(out, l)
	}
	sort.Strings(out)
	return out
}

// Normalize maps "fr-FR", "fr_FR.UTF-8" or "FR" to a known locale code, or
// returns Default for an empty or unknown code.
func Normalize(code string) string {
	c := strings.ToLower(strings.TrimSpace(code))
	if i := strings.IndexAny(c, "-_.@"); i >= 0 {
		c = c[:i]
	}
	if _, ok := catalogs[c]; ok {
		return c
	}
	return Default
}

// SetLocale selects the language of T and returns the effective code.
func SetLocale(code string) string {
	l := Normalize(code)
	current.Store(l)
	return l
}

func Locale() string { return current.Load().(string) }

// FromEnv selects the locale from NSONLINE_LANG (else Default).
func FromEnv() string { return SetLocale(os.Getenv(EnvVar)) }

// T translates key in the current locale. It falls back to English, then to
// the key itself, so a missing string is visible but never fatal.
func T(key string, args ...Args) string {
	return Translate(Locale(), key, args...)
}

func Translate(locale, key string, args ...Args) string {
	var a Args
	if len(args) > 0 {
		a = args[0]
	}
	e, ok := catalogs[Normalize(locale)][key]
	if !ok {
		if e, ok = catalogs[Default][key]; !ok {
			return key
		}
	}
	s := e.text
	if e.forms != nil {
		s = e.forms[PluralCategory(locale, a["count"])]
		if s == "" {
			s = e.forms["other"]
		}
	}
	return substitute(s, a)
}

// PluralCategory returns "one" or "other" for count in locale (CLDR rules
// for integers: English "one" is 1 only, French "one" is 0 and 1).
func PluralCategory(locale string, count any) string {
	n, ok := toFloat(count)
	if !ok {
		return "other"
	}
	switch Normalize(locale) {
	case "fr":
		if n >= 0 && n < 2 {
			return "one"
		}
	default:
		if n == 1 {
			return "one"
		}
	}
	return "other"
}

func toFloat(v any) (float64, bool) {
	switch x := v.(type) {
	case int:
		return float64(x), true
	case int32:
		return float64(x), true
	case int64:
		return float64(x), true
	case uint:
		return float64(x), true
	case float32:
		return float64(x), true
	case float64:
		return x, true
	case string:
		f, err := strconv.ParseFloat(x, 64)
		return f, err == nil
	}
	return 0, false
}

// placeholderRE matches {name}; JSON-looking text such as {"a": 1} is left alone.
var placeholderRE = regexp.MustCompile(`\{([A-Za-z_][A-Za-z0-9_]*)\}`)

func substitute(s string, a Args) string {
	if len(a) == 0 || !strings.Contains(s, "{") {
		return s
	}
	return placeholderRE.ReplaceAllStringFunc(s, func(m string) string {
		if v, ok := a[m[1:len(m)-1]]; ok {
			return fmt.Sprint(v)
		}
		return m
	})
}

// Placeholders returns the sorted placeholder names used in s.
func Placeholders(s string) []string {
	seen := map[string]bool{}
	for _, m := range placeholderRE.FindAllStringSubmatch(s, -1) {
		seen[m[1]] = true
	}
	out := make([]string, 0, len(seen))
	for k := range seen {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func Keys(locale string) []string {
	out := make([]string, 0, len(catalogs[locale]))
	for k := range catalogs[locale] {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func mustLoad(fsys fs.FS) map[string]map[string]entry {
	cats, err := load(fsys)
	if err != nil {
		panic("i18n: " + err.Error())
	}
	return cats
}

// load reads every <locale>.json at the root of fsys.
func load(fsys fs.FS) (map[string]map[string]entry, error) {
	names, err := fs.Glob(fsys, "*.json")
	if err != nil {
		return nil, err
	}
	cats := map[string]map[string]entry{}
	for _, name := range names {
		raw, err := fs.ReadFile(fsys, name)
		if err != nil {
			return nil, err
		}
		cat, err := parse(raw)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
		cats[strings.TrimSuffix(path.Base(name), ".json")] = cat
	}
	if _, ok := cats[Default]; !ok {
		return nil, fmt.Errorf("missing %s.json", Default)
	}
	return cats, nil
}

func parse(raw []byte) (map[string]entry, error) {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, err
	}
	out := make(map[string]entry, len(m))
	for k, v := range m {
		var s string
		if json.Unmarshal(v, &s) == nil {
			out[k] = entry{text: s}
			continue
		}
		var forms map[string]string
		if err := json.Unmarshal(v, &forms); err != nil {
			return nil, fmt.Errorf("key %q: want a string or {\"one\": ..., \"other\": ...}", k)
		}
		out[k] = entry{forms: forms}
	}
	return out, nil
}

// Check validates the catalogs in fsys: every locale has exactly the keys of
// en.json, with the same kind (string or plural) and the same placeholders;
// plural entries have an "other" form and only "one"/"other" forms. It
// returns one line per problem (empty when all is well).
func Check(fsys fs.FS) []string {
	cats, err := load(fsys)
	if err != nil {
		return []string{err.Error()}
	}
	var problems []string
	add := func(format string, a ...any) { problems = append(problems, fmt.Sprintf(format, a...)) }
	ref := cats[Default]
	for _, loc := range sortedLocales(cats) {
		cat := cats[loc]
		for k, e := range cat {
			if e.forms != nil {
				if e.forms["other"] == "" {
					add("%s: %q: plural without an \"other\" form", loc, k)
				}
				for f := range e.forms {
					if f != "one" && f != "other" {
						add("%s: %q: unknown plural form %q (use one/other)", loc, k, f)
					}
				}
			}
		}
		if loc == Default {
			continue
		}
		for _, k := range sortedKeys(ref) {
			e, ok := cat[k]
			if !ok {
				add("%s: missing key %q", loc, k)
				continue
			}
			r := ref[k]
			if (r.forms == nil) != (e.forms == nil) {
				add("%s: %q: plural in one file, plain string in the other", loc, k)
				continue
			}
			if want, got := strings.Join(placeholdersOf(r), ","), strings.Join(placeholdersOf(e), ","); want != got {
				add("%s: %q: placeholders {%s}, en.json has {%s}", loc, k, got, want)
			}
		}
		for _, k := range sortedKeys(cat) {
			if _, ok := ref[k]; !ok {
				add("%s: extra key %q (not in %s.json)", loc, k, Default)
			}
		}
	}
	return problems
}

// placeholdersOf is the union of the placeholders of all forms of e.
func placeholdersOf(e entry) []string {
	if e.forms == nil {
		return Placeholders(e.text)
	}
	var all []string
	for _, f := range e.forms {
		all = append(all, f)
	}
	return Placeholders(strings.Join(all, " "))
}

func sortedKeys(m map[string]entry) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func sortedLocales(c map[string]map[string]entry) []string {
	out := make([]string, 0, len(c))
	for k := range c {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// Embedded returns the catalogs compiled into the binary (for Check).
func Embedded() fs.FS { return embedded }
