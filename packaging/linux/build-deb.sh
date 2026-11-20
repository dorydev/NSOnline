#!/usr/bin/env bash
# Build NSOnline-<ver>-linux-amd64.deb (package "nsonline") with dpkg-deb.
#
# Usage: build-deb.sh <bundle dir> <output.deb> <version>
# Layout: /opt/nsonline/ (Flutter bundle + nsonline-core backend),
#         /usr/bin/nsonline-app, /usr/share/applications/dev.nsonline.app.desktop,
#         /usr/share/icons/hicolor/256x256/apps/dev.nsonline.app.png
# Environment: DEB_MAINTAINER="Name <email>" overrides the Maintainer field.
set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[[ $# -eq 3 ]] || { echo "usage: $0 <bundle dir> <output.deb> <version>" >&2; exit 2; }
BUNDLE="${1%/}"
OUT="$2"
VERSION="$3"
MAINTAINER="${DEB_MAINTAINER:-dorydev <dorydev@users.noreply.github.com>}"

command -v dpkg-deb >/dev/null || die "dpkg-deb not found (Debian/Ubuntu: apt install dpkg)"
check_bundle "$BUNDLE"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/nsonline-deb.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PKG="$WORK/nsonline"

echo "==> staging package tree"
mkdir -p "$PKG/DEBIAN" "$PKG/opt/nsonline" "$PKG/usr/bin" \
         "$PKG/usr/share/applications" "$PKG/usr/share/icons/hicolor/256x256/apps" \
         "$PKG/usr/share/doc/nsonline"
cp -a "$BUNDLE/." "$PKG/opt/nsonline/"
install -m 755 "$LINUX_PKG_DIR/nsonline-app" "$PKG/usr/bin/nsonline-app"
render_desktop "nsonline-app" "$PKG/usr/share/applications/$APP_ID.desktop"
install -m 644 "$ICON_SRC" "$PKG/usr/share/icons/hicolor/256x256/apps/$APP_ID.png"
install -m 644 "$REPO_ROOT/LICENSE" "$PKG/usr/share/doc/nsonline/copyright"

# Normalise permissions: dirs 755, files 644, executables 755.
find "$PKG" -type d -exec chmod 755 {} +
find "$PKG/opt" "$PKG/usr" -type f -exec chmod 644 {} +
chmod 755 "$PKG/opt/nsonline/nsonline" "$PKG/opt/nsonline/nsonline-core" "$PKG/usr/bin/nsonline-app"
find "$PKG/opt/nsonline/lib" -type f -name '*.so*' -exec chmod 755 {} +

INSTALLED_SIZE="$(du -sk --exclude=DEBIAN "$PKG" | cut -f1)"
sed -e "s|@VERSION@|$VERSION|" \
    -e "s|@MAINTAINER@|$MAINTAINER|" \
    -e "s|@INSTALLED_SIZE@|$INSTALLED_SIZE|" \
    "$LINUX_PKG_DIR/control.in" > "$PKG/DEBIAN/control"
chmod 644 "$PKG/DEBIAN/control"

# Refresh desktop/icon caches when the tools are present.
cat > "$PKG/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database -q /usr/share/applications || true; fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q -t /usr/share/icons/hicolor || true; fi
exit 0
POST
cp "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/postrm"
chmod 755 "$PKG/DEBIAN/postinst" "$PKG/DEBIAN/postrm"

echo "==> dpkg-deb --build"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
dpkg-deb --root-owner-group --build "$PKG" "$OUT"
dpkg-deb --info "$OUT"
echo "wrote $OUT"
