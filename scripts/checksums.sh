#!/usr/bin/env bash
# Write <dist>/SHA256SUMS for every NSOnline-<version>-* artifact in <dist>, in
# sha256sum format ("<hex>  <filename>", two spaces, bare filenames).
#
# Usage: checksums.sh <dist dir> <version>
# Works with sha256sum (Linux, Git Bash) or shasum -a 256 (macOS).
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 <dist dir> <version>" >&2; exit 2; }
DIST="$1"
VERSION="$2"

if command -v sha256sum >/dev/null; then
  hash() { sha256sum "$@"; }
elif command -v shasum >/dev/null; then
  hash() { shasum -a 256 "$@"; }
else
  echo "error: neither sha256sum nor shasum found" >&2; exit 1
fi

cd "$DIST"
shopt -s nullglob
files=("NSOnline-$VERSION-"*)
shopt -u nullglob
(( ${#files[@]} > 0 )) || { echo "error: no NSOnline-$VERSION-* files in $DIST" >&2; exit 1; }

# Strip any "*" binary-mode marker so every tool produces the same format.
hash "${files[@]}" | sed 's/  \*/  /; s/ \*/  /' | LC_ALL=C sort -k2 > SHA256SUMS.tmp
mv SHA256SUMS.tmp SHA256SUMS
cat SHA256SUMS
