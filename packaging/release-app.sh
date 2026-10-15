#!/usr/bin/env bash
# Build a distributable macrdp.app archive for a GitHub Release.
#
# Produces the SAME asset layout the release workflow publishes, so a manual
# artifact can be dropped into a release (or served to `install-remote.sh`)
# without surprises:
#
#   macrdp-<tag>-aarch64-apple-darwin-app.zip     the signed app bundle
#   SHA256SUMS                                    its SHA-256
#
# Why a zip and not a tar.gz: `ditto -c -k --keepParent` is what preserves the
# bundle's code signature, symlinks and extended attributes, and it is what CI
# uses. `install-remote.sh` extracts it with the matching `ditto -x -k`, and the
# result passes `codesign --verify --deep --strict` — plain `zip`/`unzip` does
# not. (The bare-binary `.tar.gz` is a different artifact, produced by the
# release workflow; it contains no `macrdp.app` and the installer rejects it.)
#
# Usage: packaging/release-app.sh [tag]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-$(git -C "$ROOT" describe --tags --always)}"
TARGET="${TARGET:-aarch64-apple-darwin}"
DIST="$ROOT/target/release-assets"
NAME="macrdp-$TAG-$TARGET-app"
ARCHIVE="$DIST/$NAME.zip"
mkdir -p "$DIST"

(cd "$ROOT" && cargo build --release)
# Sign into the throwaway APP_DIR, then package the canonical staged bundle.
APP_DIR="$DIST/app" SKIP_BUILD=1 "$ROOT/packaging/make-app.sh"

rm -f "$ARCHIVE" "$DIST/SHA256SUMS"
# --keepParent keeps `macrdp.app` as the archive's top-level entry (what the
# installer's `find … -name macrdp.app` expects).
ditto -c -k --keepParent "$DIST/app/macrdp.app" "$ARCHIVE"
(cd "$DIST" && shasum -a 256 "$(basename "$ARCHIVE")" > SHA256SUMS)

# Verify what we produced the same way the installer will consume it.
VERIFY="$DIST/.verify"
rm -rf "$VERIFY"
mkdir -p "$VERIFY"
ditto -x -k "$ARCHIVE" "$VERIFY"
codesign --verify --deep --strict "$VERIFY/macrdp.app"
(cd "$DIST" && shasum -a 256 -c SHA256SUMS)
rm -rf "$VERIFY"

echo "wrote $ARCHIVE"
echo "wrote $DIST/SHA256SUMS"
echo "(extracted copy verified: codesign --verify --deep --strict, sha256 -c)"
