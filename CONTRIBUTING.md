# Contributing to NSOnline

Thanks for helping! NSOnline mirrors the game a Nintendo Switch Online friend is playing to Discord Rich Presence. It has two parts:

- `backend/`: Go module `nsonline`, the `nsonline` CLI and the local backend (`nsonline app`) that the desktop app launches as a sidecar process.
- `app/`: Flutter desktop app (package `nsonline`) for macOS, Windows and Linux.

By contributing, you agree that your contribution is licensed under the project licence, **AGPL-3.0-or-later**.

## Prerequisites

| Tool | Version | Notes |
|---|---|---|
| Go | 1.22+ | `go.work` at the repo root, so run Go commands from the root with `./backend/...` |
| Flutter | 3.x (stable) | desktop support enabled (`flutter config --enable-<os>-desktop`) |
| GNU make + bash | any recent | macOS and Linux have them. On Windows use Git Bash or MSYS2 `make`, or WSL for the Linux packages. You can also skip make and use `packaging/windows/build.ps1` |
| Discord desktop app | | must be running to see the presence |

Platform toolchains:

- **macOS**: Xcode (with command line tools; `codesign`, `lipo`, `hdiutil`, `xcrun notarytool` come with it). Release signing needs an Apple Developer ID certificate.
- **Windows**: Visual Studio 2022 with the "Desktop development with C++" workload, and [Inno Setup 6.3+](https://jrsoftware.org/isinfo.php) (`iscc.exe`) for the installer.
- **Linux** (Debian/Ubuntu names): `clang cmake ninja-build pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev libayatana-appindicator3-dev libnotify-dev`, plus `dpkg-deb` (package `dpkg`) and `curl` for packaging. These are the build-time deps of the webview, tray and notification plugins (webkit2gtk 4.1 is preferred; on older distros the webview plugin falls back to 4.0 + libsoup 2.4, but a binary built against 4.1 needs 4.1 at runtime); the runtime deps are declared in the `.deb`.

`go test -race` needs cgo, so a C compiler on PATH (on Windows: install a MinGW-w64 gcc, or run the tests without `-race`).

## Project layout

```
backend/
  cmd/nsonline/          CLI entry point: main, setup, config, login/me/friends, watch, serve, rpc, app
  internal/providers/    Provider interface, registry, shared types (Friend, Presence, Game…)
    nswitch/             Switch + Switch 2 over Coral: store.go (nso-auth.json), session.go, webservices.go
      auth/              Nintendo Account: PKCE, session token, id/access token
      coral/             Coral login, Friend/List, play log, web service token
      znca/              f token and request encryption (nxapi-znca-api, nxapi-auth)
      client/            HTTP client, API errors, Retry-After, log redaction
    n3ds/ wiiu/          stubs (not implemented yet)
  internal/presence      poll loop, backoff, presence -> activity mapping, snapshot service
  internal/discord       Discord IPC client
  internal/sidecar       backend of the desktop app: owner goroutine, commands, web service cache
  internal/http          local HTTP API (package api, loopback only)
  internal/modules/      settings (settings.json), setup (CLI wizard and menu), diagnostics
  internal/lockfile      backend.lock of a running `nsonline app`
  internal/env           .env loading
  internal/secrets       build-time embedded credentials (generated, see below)
  internal/logfile       rotating redacted log file
  internal/atomicfile    atomic file writes
  internal/version       version string set with -ldflags
  test/                  black-box regression tests, French-text check
shared/
  go.mod                 module nsonline/shared (used by backend/go.mod through a replace)
  i18n/                  en.json, fr.json: every user-facing string; Go package + i18ncheck
app/
  lib/                   Flutter code (data/, models/, state/, screens/, widgets/, theme/, i18n/)
  tool/gen_i18n.dart     generates lib/i18n/strings.g.dart from shared/i18n
  test/                  Flutter tests
  macos/ windows/ linux/ platform runners
packaging/
  macos/                 entitlements.plist, sign-and-notarize.sh, make-dmg.sh
  windows/               nsonline.iss (Inno Setup), build.ps1
  linux/                 AppImage and .deb scripts and templates
scripts/                 checksums.sh, release.sh (local release helper)
Makefile                 build, test and package targets (`make help`)
```

Build outputs: `build/backend/` (backend binaries), `app/build/` (Flutter) and `dist/` (release artifacts). None of these should be committed. `dist/` is not listed in `.gitignore` yet, so add it locally (for example in `.git/info/exclude`) until it is.

## Secrets: how credentials get into the build

The app needs your **own** Discord application IDs and an **nxapi-auth client**. They are never committed.

1. `cp .env.example .env` and fill in:
   - `DISCORD_CLIENT_ID_SWITCH2`, `DISCORD_CLIENT_ID_SWITCH`, `DISCORD_CLIENT_ID` (fallback), see [Discord setup](#discord-developer-portal-setup);
   - `NXAPI_ZNCA_API_CLIENT_ID` and one of `NXAPI_ZNCA_API_CLIENT_SECRET` / `NXAPI_ZNCA_API_SHARED_SECRET`, see [nxapi-auth client](#registering-an-nxapi-auth-client);
   - `NSONLINE_CONTACT` (URL or address added to the User-Agent, required by the nxapi-znca-api terms), and optionally `NSO_APP_VERSION`.
2. `make secrets` (part of `make build`) runs `go generate ./backend/internal/secrets`. The generator reads `.env` from the repo root, or the file in `NSONLINE_ENV_FILE`, keeps only the known keys, encrypts them with AES-256-GCM using a random key created for each build, and writes `backend/internal/secrets/secrets_gen.go`, with the key split and XOR-masked across several byte slices.
3. At runtime, an environment variable with the same name overrides the embedded value (handy in development). Without `secrets_gen.go` the build still works, and values come only from the environment or `.env`.

**This is obfuscation, not protection.** It stops `strings`, casual grepping and accidental leaks. It does not stop anyone who is motivated: the key and the ciphertext are both in the binary, and the values can be read back with a debugger or by watching the process. Treat anything you put in a distributed build as recoverable. Don't use credentials that you can't afford to see extracted and rotated, and read the [nxapi-auth notes in Thirdparty.md](Thirdparty.md#client-credentials-in-a-distributed-app) before you ship a client secret in a public build.

Never commit `.env`, `secrets_gen.go`, `nso-auth*.json` or logs. Never paste their contents into issues.

### Discord developer portal setup

Discord shows the application **name** as the activity title ("Playing Nintendo Switch 2"), so create one application per console at <https://discord.com/developers/applications>:

| Application name | `.env` key |
|---|---|
| `Nintendo Switch 2` | `DISCORD_CLIENT_ID_SWITCH2` |
| `Nintendo Switch` | `DISCORD_CLIENT_ID_SWITCH` |
| (any, fallback) | `DISCORD_CLIENT_ID` |

The value is the application's **Application ID**. No client secret or bot is needed: only local RPC is used.

In each application, go to **Rich Presence -> Art Assets** and upload these images with exactly these keys:

| Key | Used for |
|---|---|
| `switch2` | large image, Switch 2 idle presence |
| `switch` | large image, Switch idle presence |
| `idle` | small image for the "Idle" (console on, no game) state |

Game artwork comes from Nintendo's image URLs and needs no asset.

Also set each application's **App Icon** (General Information) to `app/assets/icon_nuit_512.png`. Discord shows the application icon next to the user in voice channels and in the member list, and the RPC can't change it.

### Registering an nxapi-auth client

The Coral `f` token and request encryption are provided by [nxapi-znca-api](https://github.com/samuelthomas2774/nxapi-znca-api), which requires a client registered at **<https://nxapi-auth.fancy.org.uk>**:

1. Sign in and create an OAuth client. Fill in the client information (name, description, contact): it may be shown to users.
2. Request the scopes **`ca:gf ca:er ca:dr`** (generate `f`, encrypt request, decrypt response).
3. Put the client ID in `NXAPI_ZNCA_API_CLIENT_ID`, and the client secret or shared secret in the matching key.
4. Use a **separate client for development**, as the terms ask, and read [Thirdparty.md](Thirdparty.md) and the [public API terms](https://github.com/samuelthomas2774/nxapi-znca-api/blob/docs/docs/public-api-terms.md).

## Development workflow

```bash
make help            # list targets
make backend         # build/backend/<os>-<arch>/nsonline
make test            # go vet, go test -race, flutter analyze, flutter test
make i18n            # check shared/i18n and regenerate app/lib/i18n/strings.g.dart
make build           # check-env + secrets + backend + app (release)
```

Run the app against a backend you control:

- **Connect-only mode (`NSO_API`)**: start a backend yourself and point the app at it. The app then doesn't spawn anything (the original behaviour):
  ```bash
  go run ./backend/cmd/nsonline serve                     # listens on 127.0.0.1:7878
  cd app && flutter run -d macos --dart-define=NSO_API=http://127.0.0.1:7878
  ```
- **Custom sidecar (`NSO_BACKEND_PATH`)**: let the app spawn a backend binary you just built:
  ```bash
  make backend
  NSO_BACKEND_PATH="$PWD/build/backend/$(go env GOOS)-$(go env GOARCH)/nsonline" \
    bash -c 'cd app && flutter run -d macos'
  ```
  Without either, the app looks for `nsonline` next to its executable, then `<repo>/nsonline`.
- **Backend sidecar by hand**: `nsonline app --data-dir <dir>` is what the app runs (run it from a directory without `.env` if you don't want your local one loaded). It listens on a random loopback port and prints one line, `NSONLINE_READY {"addr":...,"version":...,"pid":...}`, on stdout, then exits when stdin closes. In app mode every request needs `Authorization: Bearer $NSONLINE_API_TOKEN` plus `X-NSO-RPC: 1`:
  ```bash
  export NSONLINE_API_TOKEN=$(openssl rand -hex 32)
  go run ./backend/cmd/nsonline app --data-dir /tmp/nso-dev
  # in another shell, with the port from the READY line:
  curl -H 'X-NSO-RPC: 1' -H "Authorization: Bearer $NSONLINE_API_TOKEN" http://127.0.0.1:<port>/api/health
  ```
  Use a throwaway `--data-dir`: it holds `nso-auth*.json`, `settings.json` and `logs/backend.log`.
- `--dart-define=NSO_MOCK=true` runs the UI on fake data, with no backend.

## CLI setup (`nsonline setup`, `nsonline config`)

Both commands work on the **same data dir and files** as the desktop app (`nso-auth.json`, `nso-auth-main.json`, `settings.json`). The default `--data-dir` is the app's folder:

| OS | Data dir |
|---|---|
| macOS | `~/Library/Application Support/dev.nsonline.app` |
| Windows | `%APPDATA%\nsonline\nsonline` |
| Linux | `$XDG_DATA_HOME/dev.nsonline.app` (`~/.local/share/...` when unset) |

- `nsonline setup [--data-dir <dir>] [-no-browser]` is a numbered wizard: 1. nxapi-znca-api consent, 2. observer login (prints the URL, opens the browser, you paste the `npf…://auth` link), 3. optional main account login, 4. watched account picked from the observer's friends, 5. Discord test activity, 6. intervals, idle activity and language, 7. summary and save. `settings.json` is written only at step 7: Ctrl+D (EOF) or "no" leaves it untouched. A login is saved as soon as it succeeds.
- `nsonline config [--data-dir <dir>]` is a numbered menu. Edits stay in a draft: `s` saves (the previous file is kept as `settings.json.bak`, like in the app), `c`, EOF or Ctrl+C write nothing.
- Both refuse to run while an `nsonline app` backend uses the same data dir (`backend.lock` with a live pid): the two would write the same files at the same time. Close the app first.
- The language picked there is saved as `language` in `settings.json`; `setup` and `config` use it when neither `--lang` nor `NSONLINE_LANG` is set.
- The older commands (`login`, `me`, `friends`, `watch`, `serve`) still take `-auth-file` and are unchanged.

## Adding a console

Each console family is a provider, in the style of a registry of providers with one folder each:

1. Create `backend/internal/providers/<kind>/provider.go` with a type implementing `providers.Provider`:
   ```go
   type Provider interface {
   	Kind() string
   	Platforms() []Platform            // {ID: presence.platform value, Name, Asset: Discord art key}
   	DiscordApp(platform int) string   // Discord application of that console ("" = fallback)
   	WebServices() []WebService
   	Open(path string) (Session, error) // one account, from its token file
   }
   ```
   `Session` has `LoggedIn`, `StartLogin`, `FinishLogin`, `Friends`, `Presence(target)` and `OpenWebService(id)`.
2. Register it in `init()` with `providers.Register(Provider{})` and add a blank import in `backend/cmd/nsonline/main.go`.
3. Return `providers.ErrNotImplemented` for what does not work yet (see `n3ds` and `wiiu`: Nintendo Network is closed since April 2024, the only source left is Pretendo's NEX friends server).
4. Errors should implement `Code() int`, `Wait() time.Duration` (Retry-After) and `Fatal() bool` where it applies; the presence loop and the API read them without importing your package. The same project rules apply to every provider: 15 s poll floor, backoff and Retry-After, one request at a time to rate-limited services, no tokens in logs.
5. Test each layer with `httptest` fakes, like `providers/nswitch`.

## Game web services

`GET /api/webservices` lists SplatNet 3, NookLink and Smash World. `POST /api/webservices/{id}/open` gets a web service token from Coral (f token with hash method 2, from the Coral token) with the main account, or the observer when the main account is not logged in, and returns what the app's WebView needs (URL with `lang`/`na_country`/`na_lang`, User-Agent, `X-GameWebToken` header, `_gtoken` cookie). This is the one documented exception to "no tokens in API responses": app mode only (Bearer token), never logged, `Cache-Control: no-store`. Tokens are fetched only when the user opens a service and cached until they expire: no polling.

In the app, the tray menu is a native OS menu laid out like nxapi's (account, presence checkbox, actions, then a web services section). A web service opens in a `desktop_webview_window` window. That plugin can't set request headers or cookies, so the token is set as a `_gtoken` cookie from a document-start script, followed by a single reload. This has not been checked against the real Nintendo servers yet.

## Tests and code style

- `make test` must pass before you open a PR (it also runs `go test ./shared/...`). Also check the cross builds: `GOOS=windows go build ./backend/...` and `GOOS=linux go build ./backend/...`.
- Tests never call real Nintendo, znca, nxapi-auth or Discord endpoints: use `httptest` servers and the existing fakes.
- Don't weaken or delete the audit regression suites (`backend/test/audit_test.go`, `app/test/audit/`).
- Go: `gofmt`, `go vet`, small packages, and the project style: very few comments (a short one for a protocol quirk only), small helpers first then the main function, blank lines between steps, short plain English errors, early returns, no interface where a function is enough. Dependencies are injected through `Options` functions where it keeps the loop testable. Standard library only: the backend has no external Go dependencies. No French outside `shared/i18n/fr.json` (`backend/test/french_test.go` checks it).
- Dart: `flutter analyze` clean, `dart format`, the same style as the Go code (few comments, helpers first), no French outside `shared/i18n` (`app/test/no_french_test.dart` checks it), and the shared theme tokens and widgets (`AppColors`, `AppRadii`, `widgets/common.dart`) instead of one-off styles.
- New dependencies must be AGPL-compatible and added to [Thirdparty.md](Thirdparty.md).

### Translations

Every user-facing string lives in `shared/i18n/en.json` (the reference) and `shared/i18n/fr.json`. Format and details are in [shared/i18n/README.md](shared/i18n/README.md).

1. Add a key to both files: flat dotted keys, `{name}` placeholders, plurals as `{"one": ..., "other": ...}` on `{count}`.
2. Run `make i18n`. It validates both files (same keys, same placeholders) and regenerates `app/lib/i18n/strings.g.dart`. `make app` runs it too.
3. In Dart, use the generated accessor (`S.settingsTitle`, `S.timeDaysAgo(count: n)`). In Go, use `i18n.T("key", i18n.Args{...})`.
4. Log lines are not translated: keep them as plain English strings.

The app defaults to English whatever the OS locale. Users switch it in Settings > Language. The CLI uses `--lang <code>`, else `NSONLINE_LANG`, else English. The app passes its language to the backend it spawns through `NSONLINE_LANG`. Both test suites fail on a mismatch between the files, and `flutter test` also fails when the generated Dart file is stale.

### Project rules (non-negotiable)

- **Loopback API only.** The backend listens on `127.0.0.1`. Every route checks the Host header and `X-NSO-RPC: 1` (plus the bearer token in app mode). No CORS headers.
- **The API contract is additive.** Add fields or endpoints. Never rename, remove or change the meaning of a JSON field or route. A new app must work with an older backend, and the other way round.
- **15 s poll floor.** Poll intervals are clamped to at least 15 s, errors back off, `Retry-After` is honoured, and znca calls go one at a time. Respect Nintendo and the nxapi services.
- **Nintendo isolation.** Only the poll goroutines and the sidecar's owner goroutine talk to Nintendo, Coral and znca, or touch the token store. HTTP handlers send it commands.
- **No tokens or secrets in logs or API responses.** Mask identifiers and expose booleans instead of values. The only exception is the game web service token of `POST /api/webservices/{id}/open` (see [Game web services](#game-web-services)).
- **English everywhere, texts from `shared/i18n`.** All user-facing text (app UI and CLI) is English by default and comes from the shared catalogs, never hard-coded (see [Translations](#translations)). Code, comments, identifiers, docs and log lines are plain English.

## Release process (manual, no CI)

There is no CI and no GitHub Action. Releases are built on maintainers' machines, one OS at a time, and uploaded by hand.

1. `scripts/release.sh bump X.Y.Z` (updates `app/pubspec.yaml`, the single source of the version), then review and commit it yourself.
2. On each OS: `scripts/release.sh build`. This runs `make test`, `make package-<os>` and `make checksums`, which produce in `dist/`:
   - macOS: `NSOnline-X.Y.Z-macos-universal.zip` (signed, notarized .app, used by the updater) and `NSOnline-X.Y.Z-macos-universal.dmg`;
   - Windows: `NSOnline-X.Y.Z-windows-x64-setup.exe`;
   - Linux: `NSOnline-X.Y.Z-linux-x86_64.AppImage` and `NSOnline-X.Y.Z-linux-amd64.deb`.
3. Gather every artifact into one `dist/`, then either run `make checksums` there or merge the per-OS files with `scripts/release.sh merge dist/SHA256SUMS.macos dist/SHA256SUMS.windows dist/SHA256SUMS.linux`. Check with `scripts/release.sh verify`.
4. `scripts/release.sh upload-help` prints the manual steps: tag `vX.Y.Z`, create the GitHub release and attach the five artifacts plus `SHA256SUMS`, published as a normal release (the updater ignores drafts and pre-releases). It shows an optional `gh release create` command but never runs it.

Linux packaging downloads `appimagetool` 1.9.1 into `~/.cache/nsonline/` the first time and checks it against a pinned SHA-256 (see `packaging/linux/build-appimage.sh`). Set `APPIMAGETOOL=/path/to/appimagetool` to use your own copy.

### Signing per OS

- **macOS**: needs a *Developer ID Application* certificate in your keychain, and a notarytool profile created once:
  ```bash
  xcrun notarytool store-credentials nsonline-notary --apple-id you@example.com --team-id TEAMID --password <app-specific password>
  export APPLE_DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" APPLE_TEAM_ID=TEAMID NOTARY_PROFILE=nsonline-notary
  make package-macos
  ```
  `sign-and-notarize.sh` signs the embedded `nsonline` binary first, then the `.app`, with the hardened runtime and `packaging/macos/entitlements.plist` (network client and server, JIT for Flutter, no sandbox). It then notarizes, staples and verifies the result. `make-dmg.sh` does the same for the dmg. `NSONLINE_UNSIGNED=1 make package-macos` produces unsigned artifacts for local testing only: Gatekeeper blocks them on other Macs.
- **Windows**: the installer and executables are currently **unsigned**, so SmartScreen shows "Windows protected your PC" on first run ("More info -> Run anyway"). The installer is per-user (no admin rights), which lets the in-app updater run it silently.
- **Linux**: AppImage and `.deb` are unsigned. Users can check the files against `SHA256SUMS`.

## Reporting issues

The easiest way is the in-app **"Report a problem"** button (Settings > Help). It uses the app version, your OS and the redacted logs (`logs/backend.log`, `logs/app.log` in the app data folder) to prepare a GitHub issue that you review before sending. Otherwise open an issue at <https://github.com/dorydev/NSOnline/issues> with your OS, the app version, steps to reproduce and the relevant log lines. Check that no token, session token or `.env` value appears in anything you paste.

Security problems (for example a way to reach the local API from a web page): please don't open a public issue. Contact the maintainer privately through GitHub first.

### Game web services (disabled in 0.1.0)

SplatNet 3, NookLink and Smash World are implemented (backend routes `/api/webservices`, app cards, tray section) but turned off: the pages stay on their loader because desktop_webview_window can't send the `X-GameWebToken` header on the first request, and the `_gtoken` cookie workaround isn't enough. Fixing it needs native code to load the first request with headers (WKWebView `load(URLRequest)`, WebView2 `NavigateWithWebResourceRequest`, WebKitGTK `webkit_web_view_load_request`).

To work on it, build the app with:

```bash
cd app && flutter run -d macos --dart-define=NSONLINE_WEB_SERVICES=true
```
