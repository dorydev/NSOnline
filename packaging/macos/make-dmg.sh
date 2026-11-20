#!/usr/bin/env bash
# Build NSOnline-<ver>-macos-universal.dmg (first-install image) with hdiutil
# only, then sign, notarize and staple it.
#
# Usage: make-dmg.sh <path/to/nsonline.app> <output.dmg> <version>
# Run sign-and-notarize.sh first so the .app inside is already notarized.
# Same environment as sign-and-notarize.sh (APPLE_DEVELOPER_ID, APPLE_TEAM_ID,
# NOTARY_PROFILE, NSONLINE_UNSIGNED=1).
set -euo pipefail

[[ $# -eq 3 ]] || { echo "usage: $0 <App.app> <output.dmg> <version>" >&2; exit 2; }
APP="${1%/}"
DMG="$2"
VERSION="$3"
VOLNAME="NSOnline $VERSION"

[[ -d "$APP" ]] || { echo "error: $APP not found" >&2; exit 1; }

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/nsonline-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

# Keep the bundle name identical to the one in the updater zip, so an update
# replaces the bundle installed from the dmg. Add the usual /Applications link.
ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"

mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -fs HFS+ -format UDZO "$DMG"

if [[ "${NSONLINE_UNSIGNED:-}" == "1" ]]; then
  echo "warning: NSONLINE_UNSIGNED=1, dmg left unsigned" >&2
  echo "wrote $DMG"
  exit 0
fi

: "${APPLE_DEVELOPER_ID:?set APPLE_DEVELOPER_ID}"
: "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE}"

codesign --force --timestamp --sign "$APPLE_DEVELOPER_ID" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --team-id "$APPLE_TEAM_ID" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"

echo "wrote $DMG"
