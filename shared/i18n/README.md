# shared/i18n: user-facing strings

Single source of truth for every user-facing text of NSOnline: the desktop app (Flutter, `app/`) and the backend (CLI usage and help, prompts, Discord activity texts, API error messages). English is the default and the reference; French is a full translation.

| File | Role |
|---|---|
| `en.json` | English, the reference: every key must exist here |
| `fr.json` | French: exactly the keys of `en.json` |
| `i18n.go` | Go package `nsonline/shared/i18n` (module `nsonline/shared`, `go.mod` one level up): embeds the JSON files, `T(key, args)` |
| `cmd/i18ncheck` | validator: `go run ./shared/i18n/cmd/i18ncheck [dir]` |

## Format

Each file is one flat JSON object. Keys are dotted, grouped by area (`home.*`, `settings.*`, `setup.*`, `tray.*`, `presence.*`, `cli.*`, `api.error.*`…). A value is either:

- a string, with optional `{name}` placeholders:
  ```json
  "home.inGameFor": "In game · {duration}"
  ```
- or a plural object chosen by the `count` argument, with the forms `one` and `other` (`other` is required):
  ```json
  "time.daysAgo": { "one": "{count} day ago", "other": "{count} days ago" }
  ```
  English uses `one` for 1 only. French uses it for 0 and 1.

A placeholder is `{` + identifier + `}`. Other braces (for example `{"enabled": true}` in an API message) are left alone. A missing argument leaves the placeholder visible, a missing key falls back to English, then to the key itself.

## Rules

1. Add the key to **both** files, with the same placeholders, and the same kind (string or plural).
2. No hard-coded user-facing text in `app/lib` or `backend/`: use a key. Log lines are the exception: they stay plain English strings.
3. After any change, run `make i18n` from the repo root. It validates the catalogs, then regenerates `app/lib/i18n/strings.g.dart`.
4. Never edit `strings.g.dart` by hand. Keep JSON field names and API routes out of the catalogs: only texts go here.

The checks run in both test suites. `go test ./shared/...` fails on a key, placeholder or plural mismatch. `flutter test` (`app/test/i18n_test.dart`) fails on the same mismatches and also when `strings.g.dart` is stale.

## How each side reads it

- **Go**: `go:embed` cannot reach outside a module, so the catalogs live in their own module `nsonline/shared` (`shared/go.mod`), listed in `go.work` and required by `backend/go.mod` with `replace nsonline/shared => ../shared`. Use `i18n.T("presence.idle")` or `i18n.T("presence.hours", i18n.Args{"count": 2})`. The locale comes from `--lang <code>` (global CLI flag), else `NSONLINE_LANG`, else `en`. The desktop app sets `NSONLINE_LANG` when it starts `nsonline app`.
- **Flutter**: Flutter assets must live inside the package, so `app/tool/gen_i18n.dart` compiles the JSON into `app/lib/i18n/strings.g.dart`. That means no runtime file I/O, and it works in tests. Use the typed accessors, `S.homeFriendsTitle` or `S.timeDaysAgo(count: 3)` (`count` is a `num`, other placeholders take any object), or `t('key', {...})` for a key built at runtime. The language is `appLocale` (`lib/i18n/i18n.dart`). It is saved as `language` in `app_prefs.json`, defaults to English whatever the OS locale, and changes at once from Settings > Language.
