#!/usr/bin/env bash
# Sign the NSOnline .app with a Developer ID, notarize it, staple the ticket and
# produce the updater zip (NSOnline-<ver>-macos-universal.zip).
#
# Usage: sign-and-notarize.sh <path/to/nsonline.app> <output.zip>
#
# Environment:
#   APPLE_DEVELOPER_ID  "Developer ID Application: Your Name (TEAMID)"
#   APPLE_TEAM_ID       10-character team id
#   NOTARY_PROFILE      keychain profile created once with:
#                         xcrun notarytool store-credentials <profile> \
#                           --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
#   NSONLINE_UNSIGNED=1 skip signing/notarization and only zip (local testing;
#                       the result will be blocked by Gatekeeper on other Macs)
set -euo pipefail

usage() { echo "usage: $0 <App.app> <output.zip>" >&2; exit 2; }
[[ $# -eq 2 ]] || usage

APP="${1%/}"
ZIP="$2"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS="$HERE/entitlements.plist"
BACKEND="$APP/Contents/MacOS/nsonline-core"

[[ -d "$APP" ]] || { echo "error: $APP not found (run make app first)" >&2; exit 1; }
[[ -x "$BACKEND" ]] || { echo "error: $BACKEND missing: the backend must be embedded before signing" >&2; exit 1; }

mkdir -p "$(dirname "$ZIP")"
rm -f "$ZIP"

if [[ "${NSONLINE_UNSIGNED:-}" == "1" ]]; then
  echo "warning: NSONLINE_UNSIGNED=1, producing an UNSIGNED zip" >&2
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "wrote $ZIP"
  exit 0
fi

: "${APPLE_DEVELOPER_ID:?set APPLE_DEVELOPER_ID (\"Developer ID Application: ...\")}"
: "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE (xcrun notarytool store-credentials)}"

case "$APPLE_DEVELOPER_ID" in
  *"($APPLE_TEAM_ID)"*) ;;
  *) echo "warning: APPLE_DEVELOPER_ID does not mention team $APPLE_TEAM_ID" >&2 ;;
esac

sign() {
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$APPLE_DEVELOPER_ID" "$@"
}

echo "==> signing nested frameworks and dylibs"
# Inside-out: nested code first, the bundle last (no --deep for signing).
while IFS= read -r -d '' item; do
  codesign --force --options runtime --timestamp --sign "$APPLE_DEVELOPER_ID" "$item"
done < <(find "$APP/Contents/Frameworks" \( -name '*.dylib' -o -name '*.framework' \) -prune -print0 2>/dev/null || true)

echo "==> signing embedded backend"
sign "$BACKEND"

echo "==> signing app bundle"
sign "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> zipping for notarization"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> notarizing (this can take a few minutes)"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --team-id "$APPLE_TEAM_ID" --wait

echo "==> stapling"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Re-create the zip so the shipped archive contains the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> verifying"
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -vv "$APP"

echo "wrote $ZIP"
