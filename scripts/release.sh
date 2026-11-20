#!/usr/bin/env bash
# Local release helper for NSOnline. There is NO CI: every step runs on a
# maintainer's machine, one OS at a time, and the upload to GitHub is manual.
#
#   scripts/release.sh bump <x.y.z>       set app/pubspec.yaml to x.y.z+<build+1>
#   scripts/release.sh build              make build + package-<host os> + checksums
#   scripts/release.sh merge <sums...>    merge per-OS SHA256SUMS files into dist/SHA256SUMS
#   scripts/release.sh verify             check dist/SHA256SUMS against dist/
#   scripts/release.sh upload-help        print the manual upload steps (runs nothing)
#
# This script never commits, tags, pushes or uploads anything.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBSPEC="$ROOT/app/pubspec.yaml"
DIST="$ROOT/dist"

die() { echo "error: $*" >&2; exit 1; }
current_version() { sed -n 's/^version:[[:space:]]*\([^+[:space:]]*\).*/\1/p' "$PUBSPEC"; }
current_build() { sed -n 's/^version:[[:space:]]*[^+[:space:]]*+\([0-9]*\).*/\1/p' "$PUBSPEC"; }

sha_check() {
  if command -v sha256sum >/dev/null; then sha256sum -c "$@"; else shasum -a 256 -c "$@"; fi
}

cmd_bump() {
  local new="${1:-}"
  [[ "$new" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: release.sh bump <x.y.z>"
  local build; build="$(current_build)"; build="${build:-0}"
  local next=$((build + 1))
  local tmp; tmp="$(mktemp)"
  sed "s/^version:.*/version: $new+$next/" "$PUBSPEC" > "$tmp" && mv "$tmp" "$PUBSPEC"
  echo "app/pubspec.yaml -> version: $new+$next"
  echo "Next: update the README version badge if you want, review 'git diff', then commit yourself."
}

cmd_build() {
  local os target
  case "$(uname -s)" in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) die "unsupported OS" ;;
  esac
  target="package-$os"
  make -C "$ROOT" test
  make -C "$ROOT" "$target"          # depends on: check-env secrets backend app
  make -C "$ROOT" checksums
  mkdir -p "$DIST"
  cp "$DIST/SHA256SUMS" "$DIST/SHA256SUMS.$os"
  echo "Per-OS sums saved to dist/SHA256SUMS.$os; bring it (and the artifacts) to the release machine."
}

cmd_merge() {
  (( $# > 0 )) || die "usage: release.sh merge <SHA256SUMS.macos> <SHA256SUMS.windows> ..."
  mkdir -p "$DIST"
  # One line per filename; refuse two different hashes for the same file.
  # Normalise CRLF (files coming from Windows) first.
  cat "$@" | tr -d '\r' | sed '/^[[:space:]]*$/d' | LC_ALL=C sort -u -k2 -k1 | awk '
    { if (($2 in seen) && seen[$2] != $1) { print "conflicting hashes for " $2 > "/dev/stderr"; bad=1 }
      seen[$2]=$1; line[$2]=$0 }
    END { if (bad) exit 1; for (f in line) print line[f] }' | LC_ALL=C sort -k2 > "$DIST/SHA256SUMS.tmp"
  mv "$DIST/SHA256SUMS.tmp" "$DIST/SHA256SUMS"
  cat "$DIST/SHA256SUMS"
}

cmd_verify() {
  [[ -f "$DIST/SHA256SUMS" ]] || die "dist/SHA256SUMS not found"
  (cd "$DIST" && sha_check SHA256SUMS)
}

cmd_upload_help() {
  local v; v="$(current_version)"
  cat <<TXT
Manual GitHub release for v$v (nothing below is executed by this script):

 1. Make sure every artifact is in dist/ and 'scripts/release.sh verify' passes:
      NSOnline-$v-macos-universal.zip      NSOnline-$v-macos-universal.dmg
      NSOnline-$v-windows-x64-setup.exe
      NSOnline-$v-linux-x86_64.AppImage    NSOnline-$v-linux-amd64.deb
      SHA256SUMS
 2. Commit the version bump and create the tag yourself:
      git tag -a v$v -m "NSOnline $v" && git push origin v$v
 3. On https://github.com/dorydev/NSOnline/releases/new choose tag v$v, title
    "NSOnline $v", write the notes, attach the six files above, and publish as a
    normal release (not draft, not pre-release: the in-app updater ignores both).

 Optional, with the GitHub CLI (shown only, run it yourself if you want):
      gh release create v$v --repo dorydev/NSOnline --title "NSOnline $v" --notes-file NOTES.md \\
        dist/NSOnline-$v-macos-universal.zip dist/NSOnline-$v-macos-universal.dmg \\
        dist/NSOnline-$v-windows-x64-setup.exe \\
        dist/NSOnline-$v-linux-x86_64.AppImage dist/NSOnline-$v-linux-amd64.deb \\
        dist/SHA256SUMS
TXT
}

case "${1:-}" in
  bump) shift; cmd_bump "$@" ;;
  build) cmd_build ;;
  merge) shift; cmd_merge "$@" ;;
  verify) cmd_verify ;;
  upload-help) cmd_upload_help ;;
  *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
