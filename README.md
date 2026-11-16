# NSOnline - Nintendo rich presence for discord

<p align="center">
  <img src="https://img.shields.io/badge/version-0.0.1-blue"/>
  <img src="https://img.shields.io/badge/MacOS-12+-black?logo=Apple" />
  <img src="https://img.shields.io/badge/Windows-10+-blue?logo=microsoft" />
  <img src="https://img.shields.io/badge/Linux-AppImage%20%7C%20deb-yellow?logo=Linux"/>
  <img src="https://img.shields.io/github/go-mod/go-version/dorydev/NSOnline?filename=backend/go.mod"/>
  <img src="https://img.shields.io/badge/Language-Flutter-lightblue" />
  <img src="https://img.shields.io/github/stars/dorydev/NSOnline"/>
</p>

</br>

Nintendo Switch Online rich presence for discord.

## Prerequisites

- `Go 1.22+` (for the CLI)
- `Flutter 3.x` (for the desktop app only)
- The Discord desktop app, running
- A client registered with `nxapi-auth` (see Configuration)

## Build in CLI

```bash
go build -o nsonline ./backend/cmd/nsonline   # From root
./nsonline login      # Login PKCE, write nso-auth.json
./nsonline me         # Show your profile 
./nsonline friends    # Coral login, show your friends
```


## License & credits

Copyright (C) 2026 dorydev

This program is free software: you may redistribute and/or modify it under the terms of the GNU Affero General Public License published by the Free Software Foundation, version 3 of the license or (at your option) any later version (`AGPL-3.0-or-later`, the same license as nxapi). It is distributed without any warranty. See [LICENSE](LICENSE).

The Coral protocol, the `f` stream, and encryption have been documented using [nxapi](https://github.com/samuelthomas2774/nxapi). The `f` stream and encryption are provided by [nxapi-znca-api] (https://github.com/samuelthomas2774/nxapi-znca-api), and you must comply with its [terms of use](https://github.com/samuelthomas2774/nxapi-znca-api/blob/docs/docs/public-api-terms.md).

This project is neither affiliated with Nintendo nor endorsed by Nintendo.
