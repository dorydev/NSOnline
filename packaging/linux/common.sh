# Shared helpers for the Linux packaging scripts (sourced, not executed).
# shellcheck shell=bash

LINUX_PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LINUX_PKG_DIR/../.." && pwd)"
APP_ID="dev.nsonline.app"
# The Linux runner has no icon of its own: reuse the 256 px macOS app icon.
ICON_SRC="${NSONLINE_ICON:-$REPO_ROOT/app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_256.png}"

die() { echo "error: $*" >&2; exit 1; }

# check_bundle <dir>: the Flutter release bundle with the backend next to nsonline.
check_bundle() {
  local b="$1"
  [[ -x "$b/nsonline" ]] || die "$b/nsonline not found (run make app)"
  [[ -x "$b/nsonline-core" ]] || die "$b/nsonline-core missing: the backend must be copied into the bundle"
  [[ -d "$b/lib" && -d "$b/data" ]] || die "$b is not a Flutter bundle (lib/ and data/ expected)"
  [[ -f "$ICON_SRC" ]] || die "icon $ICON_SRC not found (set NSONLINE_ICON)"
}

# render_desktop <exec> <dest>
render_desktop() {
  sed "s|@EXEC@|$1|" "$LINUX_PKG_DIR/nsonline.desktop.in" > "$2"
}
