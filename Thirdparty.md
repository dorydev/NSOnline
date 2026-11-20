# Third-party services, software and licences

NSOnline is free software under **AGPL-3.0-or-later** (see [LICENSE](LICENSE)). It depends on several third-party services and libraries. This page explains what each one is, what data goes to it, and which terms apply. It is a summary written for contributors and users, not legal advice: the linked documents are the reference. The summaries below were checked against those documents in November 2026.

**Nintendo non-affiliation.** NSOnline is neither affiliated with nor endorsed by Nintendo. "Nintendo", "Nintendo Switch", "Nintendo Switch 2" and "Nintendo Switch Online" are trademarks of Nintendo. NSOnline uses the same non-public APIs as the official Nintendo Switch app (Coral), with your own Nintendo Account. Using them may be against Nintendo's terms, and Nintendo can change or block them at any time.

## nxapi-znca-api and nxapi-auth

### What they are

- **[nxapi-znca-api](https://github.com/samuelthomas2774/nxapi-znca-api)** is a server, by Samuel Elliott, that generates the `f` parameter needed to sign in to Coral (the Nintendo Switch Online app API). It also encrypts and decrypts Coral requests and responses. It works by calling the token-generation functions of the official Nintendo Switch Online app on a real Android device. NSOnline uses the public instance, `https://nxapi-znca-api.fancy.org.uk`. Its README asks developers to get in touch with the maintainer (through the nxapi Discord server) to use the public server, and to disclose to users that their `id_token` is sent to a third-party API.
- **[nxapi-auth](https://nxapi-auth.fancy.org.uk)** is the OAuth 2 server that issues the access tokens nxapi-znca-api requires ("From June 2025, authentication is required"). Developers register a client at `https://nxapi-auth.fancy.org.uk/oauth/clients`. Documentation: [docs/api-auth.md](https://github.com/samuelthomas2774/nxapi-znca-api/blob/docs/docs/api-auth.md) and [docs/api.md](https://github.com/samuelthomas2774/nxapi-znca-api/blob/docs/docs/api.md).

### Client registration and scopes

- Each developer or fork registers **their own** client and fills in the client information (name, description, contact). nxapi-auth may show it to users.
- NSOnline requests `ca:gf` (generate `f`), `ca:er` (encrypt request) and `ca:dr` (decrypt response). All clients can request these. `ca:da` (decrypt any) requires approval, is limited to confidential clients, is meant for development only, and NSOnline does not use it.
- Tokens come from `POST https://nxapi-auth.fancy.org.uk/api/oauth/token` (`client_credentials` grant, then `refresh_token`). Tokens are short-lived, **must not be saved persistently**, and each token covers **one Coral user**, so the observer and main accounts get separate tokens. On `invalid_grant` while refreshing, request a new token with the client credentials. Don't retry other `invalid_grant` errors.
- The terms ask for a **separate client identifier for development**.

### What data passes through them

When you sign in, the following go to nxapi-znca-api, and so to a third party outside Nintendo:

- your Nintendo Account **`id_token`** (to compute the Coral sign-in `f`);
- your **Coral token** (web service token);
- **all data sent to and received from the Coral API** that NSOnline asks it to encrypt or decrypt: your friend list, friends' presence and current game, your profile, play history.

Your Nintendo **session token** stays on your machine (`nso-auth*.json` in the app data folder, file mode 0600) and is not sent to nxapi-znca-api. NSOnline sends no data of its own to the project or its maintainers.

### User consent

The public API terms require clients to tell users, **before** asking them to sign in with their Nintendo Account, that their id_token, Coral token and Coral data are sent to a third-party API, to link to the project, and to get an **explicit acknowledgement before any contact** with those services. NSOnline shows this notice during setup and records the acceptance (`POST /api/ack`) in both account stores. It makes no znca call until you accept. You can sign out at any time, which deletes the token files and stops all requests for that account.

### Usage and rate expectations (from the terms and docs)

- Imitate the official Nintendo apps as closely as possible, and renew tokens only as they do. Cache tokens for their full validity.
- Requests to Nintendo services with a user's account should come from that user's interaction. **Automated requests are allowed only at a limited frequency, only if the user explicitly allowed them, and only if the user has interacted with the service recently.** For users who are not interacting, only **one concurrent request** is allowed. NSOnline's background polling depends on this clause: it polls no more often than every 15 s, runs one znca request at a time, and backs off on errors.
- **No automatic retries** to nxapi-znca-api or to Nintendo, except when the connection closed before a response, or as `Retry-After` says. NSOnline honours `Retry-After` and backs off instead of retrying in a loop.
- Published rate limits (docs/api.md): Coral authentication (hash method 1) 10 requests per 60 min per Nintendo Account; web service authentication (hash method 2) 20 requests per 30 min per Coral user. Above these, the API returns `rate_limit` (429).
- An `invalid_grant` from Nintendo means the session token should be deleted.
- Clients made available to other users should avoid user authentication where possible (dedicated accounts for public data). Features that use these APIs or their data **must be free**, with no paid subscription and no advertising. Optional donations are allowed. NSOnline is free and has no ads.

### User-Agent and contact requirement

The terms require a `User-Agent` header with the **project name, version and contact details**, preferably `project/version (+url)`. Libraries should add their own component too. NSOnline builds its User-Agent from its version and `NSONLINE_CONTACT`, so **set `NSONLINE_CONTACT` to a URL or address where the operator of your build can be reached** before you distribute it. The terms also ask for `X-znca-Platform`/`X-znca-Version` (the app version imitated, see `NSO_APP_VERSION`) and a fixed `X-znca-Client-Version` that must never be set dynamically.

### Client credentials in a distributed app

This affects how NSOnline embeds credentials (see [CONTRIBUTING.md](CONTRIBUTING.md#secrets-how-credentials-get-into-the-build)):

- The terms distinguish **confidential clients** ("authentication must use a client secret or client assertion"), which reach the API from the developer's server, from **public clients**, which reach it from the user's device ("authentication may optionally use a client assertion or only the client identifier").
- A desktop app installed by users runs on the user's device, so it is a **public client** in those terms. Neither the terms nor the auth docs explicitly forbid shipping a client secret inside an app, but the model assumes a public client has no real secret. A secret embedded in a binary, even obfuscated with AES-GCM, can be extracted and reused by anyone.
- The auth docs describe client assertions as RS256 JWTs whose header has a `jku` and a `kid`. The project's `.env.example` mentions a "shared secret" that signs an HS256 assertion, which the public docs don't describe. Check the client page on nxapi-auth for the methods it currently offers.
- **Recommendation for public builds:** register the distributed client as a public client and ship only `NXAPI_ZNCA_API_CLIENT_ID`, unless the nxapi-znca-api maintainer agrees to something else. Keep any client secret or shared secret for private/dev builds, use a separate development client, and be ready to rotate anything that has shipped.

Full terms: **[nxapi-znca-api public API terms](https://github.com/samuelthomas2774/nxapi-znca-api/blob/docs/docs/public-api-terms.md)**. Every build that talks to the public server must comply with them.

## nxapi

[nxapi](https://github.com/samuelthomas2774/nxapi) by Samuel Elliott documents the Nintendo Account, Coral, `f` and encryption flows that NSOnline implements. NSOnline is an independent Go implementation that builds on that documentation. nxapi is licensed **AGPL-3.0-or-later**, and NSOnline uses the same licence. Thanks to its author and contributors.

## Discord Rich Presence

NSOnline talks to the **local Discord desktop client** over its IPC socket (Unix socket or Windows named pipe) using your own Discord application IDs. It doesn't call the Discord HTTP API and needs no bot token or client secret. The activity contains the game name, Nintendo's game artwork URL, timestamps and the console name. Anyone who can see your Discord profile can see it. Use of Discord's platform is governed by the [Discord Developer Terms of Service](https://discord.com/developers/docs/policies-and-agreements/developer-terms-of-service) and the [Discord Developer Policy](https://discord.com/developers/docs/policies-and-agreements/developer-policy). Each developer who builds NSOnline creates their own Discord applications and is responsible for them.

## Other network services

- **Nintendo** (`accounts.nintendo.com`, `api-lp1.znc.srv.nintendo.net` and related hosts): sign-in and Coral data, with your account.
- **GitHub** (`api.github.com/repos/dorydev/NSOnline/releases/latest`, release downloads): the in-app updater checks at startup and every 6 hours. Only a standard request; no personal data is added. [GitHub Terms of Service](https://docs.github.com/site-policy/github-terms/github-terms-of-service).
- **Google Fonts**: the `google_fonts` package downloads the font files it needs from Google's servers (`fonts.gstatic.com`) at runtime and caches them, unless the fonts are bundled as assets (they aren't today). [Google Fonts FAQ / privacy](https://developers.google.com/fonts/faq/privacy).

## Software dependencies

Go backend (`backend/go.mod`): **no third-party modules**, standard library only. Go is BSD-3-Clause.

Flutter app (direct dependencies from `app/pubspec.yaml`; licences checked in each package's `LICENSE` file at the version listed):

| Package | Version | Licence | Purpose |
|---|---|---|---|
| flutter (SDK) | 3.x | BSD-3-Clause | UI framework, engine |
| cupertino_icons | ^1.0.8 | MIT | icon font |
| google_fonts | ^8.2.1 | BSD-3-Clause (fonts: SIL OFL 1.1 / Apache-2.0 per family) | typography |
| http | ^1.6.0 | BSD-3-Clause | local API client |
| url_launcher | ^6.3.3 | BSD-3-Clause | open links in the browser |
| font_awesome_flutter | ^11.0.0 | MIT (Font Awesome Free icons: CC BY 4.0, font: SIL OFL 1.1) | brand icons |
| characters | ^1.4.1 | BSD-3-Clause | grapheme-safe strings |
| path_provider | ^2.1.6 | BSD-3-Clause | app data directory |
| window_manager | ^0.5.2 | MIT | window control |
| tray_manager | ^0.5.3 | MIT | system tray (Linux: libayatana-appindicator3 / libappindicator3) |
| desktop_webview_window | ^0.4.3 | Apache-2.0 | Nintendo sign-in webview (Linux: webkit2gtk 4.1, or 4.0) |
| launch_at_startup | ^0.5.1 | MIT | start at login |
| crypto | ^3.0.8 | BSD-3-Clause | hashing (e.g. PKCE challenge) |
| local_notifier | ^0.1.6 | MIT | desktop notifications (Linux: libnotify) |
| flutter_lints (dev) | ^6.0.0 | BSD-3-Clause | lints, not shipped |

These packages pull in transitive dependencies (platform interfaces and federated implementations, mostly BSD-3-Clause from the Flutter and Dart teams). `flutter pub deps` lists them, and the app's licence page (`showLicensePage`) shows every licence bundled in a release build. All of them are compatible with AGPL-3.0-or-later.

Build and packaging tools (not shipped in the app): [appimagetool](https://github.com/AppImage/appimagetool) (MIT; it embeds the AppImage type2 runtime in the generated AppImage, see that project for its licence), [Inno Setup](https://jrsoftware.org/isinfo.php) (Inno Setup licence, free for commercial use), Apple Xcode tools, `dpkg-deb`.

**Keep this list up to date.** When you add, remove or upgrade a dependency in `app/pubspec.yaml` or `backend/go.mod`, update this table in the same change, and check that the licence is AGPL-compatible.
