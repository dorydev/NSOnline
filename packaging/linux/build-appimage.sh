#!/usr/bin/env bash
# Build NSOnline-<ver>-linux-x86_64.AppImage from the Flutter Linux bundle.
#
# Usage: build-appimage.sh <bundle dir> <output.AppImage> <version>
#
# appimagetool: downloaded on demand (pinned version + SHA-256 below) into
# ${XDG_CACHE_HOME:-~/.cache}/nsonline/. Set APPIMAGETOOL=/path/to/appimagetool
# to use your own copy instead. Note: appimagetool >= 1.9 itself downloads the
# AppImage type2 runtime from GitHub unless you pass a runtime file
# (APPIMAGE_RUNTIME_FILE=/path/to/runtime-x86_64).
set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

[[ $# -eq 3 ]] || { echo "usage: $0 <bundle dir> <output.AppImage> <version>" >&2; exit 2; }
BUNDLE="${1%/}"
OUT="$2"
VERSION="$3"

# Pinned appimagetool. Digest taken from the GitHub release asset metadata of
# https://github.com/AppImage/appimagetool/releases/tag/1.9.1 . To bump: change
# both values and re-check the digest on the release page.
APPIMAGETOOL_VERSION="1.9.1"
APPIMAGETOOL_SHA256="ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/${APPIMAGETOOL_VERSION}/appimagetool-x86_64.AppImage"

[[ "$(uname -m)" == "x86_64" ]] || die "the AppImage is built for x86_64 only"
check_bundle "$BUNDLE"

get_appimagetool() {
  if [[ -n "${APPIMAGETOOL:-}" ]]; then
    [[ -x "$APPIMAGETOOL" ]] || die "APPIMAGETOOL=$APPIMAGETOOL is not executable"
    echo "$APPIMAGETOOL"; return
  fi
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/nsonline"
  local tool="$cache/appimagetool-${APPIMAGETOOL_VERSION}-x86_64.AppImage"
  mkdir -p "$cache"
  if [[ ! -x "$tool" ]]; then
    echo "==> downloading appimagetool ${APPIMAGETOOL_VERSION}" >&2
    curl -fsSL --retry 3 -o "$tool.part" "$APPIMAGETOOL_URL"
    echo "${APPIMAGETOOL_SHA256}  $tool.part" | sha256sum -c - >&2 \
      || { rm -f "$tool.part"; die "appimagetool checksum mismatch"; }
    chmod +x "$tool.part"
    mv "$tool.part" "$tool"
  else
    echo "${APPIMAGETOOL_SHA256}  $tool" | sha256sum -c --status - \
      || die "cached $tool does not match the pinned checksum; delete it"
  fi
  echo "$tool"
}

TOOL="$(get_appimagetool)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/nsonline-appimage.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APPDIR="$WORK/NSOnline.AppDir"

echo "==> assembling AppDir"
mkdir -p "$APPDIR/usr/lib/nsonline" "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps"
cp -a "$BUNDLE/." "$APPDIR/usr/lib/nsonline/"
install -m 755 "$LINUX_PKG_DIR/AppRun" "$APPDIR/AppRun"
render_desktop "nsonline" "$APPDIR/$APP_ID.desktop"
cp "$APPDIR/$APP_ID.desktop" "$APPDIR/usr/share/applications/$APP_ID.desktop"
install -m 644 "$ICON_SRC" "$APPDIR/$APP_ID.png"
install -m 644 "$ICON_SRC" "$APPDIR/usr/share/icons/hicolor/256x256/apps/$APP_ID.png"
ln -s "$APP_ID.png" "$APPDIR/.DirIcon"

echo "==> running appimagetool"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
args=()
[[ -n "${APPIMAGE_RUNTIME_FILE:-}" ]] && args+=(--runtime-file "$APPIMAGE_RUNTIME_FILE")
# Extract-and-run avoids needing FUSE on the build machine (containers, WSL).
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 VERSION="$VERSION" \
  "$TOOL" "${args[@]+"${args[@]}"}" "$APPDIR" "$OUT"
chmod 755 "$OUT"
echo "wrote $OUT"
