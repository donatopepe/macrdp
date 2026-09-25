#!/usr/bin/env bash
# Build a distributable macrdp.app archive for a GitHub Release.
# Usage: packaging/release-app.sh [tag]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-$(git -C "$ROOT" describe --tags --always)}"
DIST="$ROOT/target/release-assets"
ARCHIVE="$DIST/macrdp-$TAG-macos-arm64.tar.gz"
mkdir -p "$DIST"

(cd "$ROOT" && cargo build --release)
APP_DIR="$DIST/app" SKIP_BUILD=1 "$ROOT/packaging/make-app.sh"
rm -f "$ARCHIVE" "$ARCHIVE.sha256"
tar -C "$DIST/app" -czf "$ARCHIVE" macrdp.app
(cd "$DIST" && shasum -a 256 "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256")
echo "wrote $ARCHIVE"
echo "wrote $ARCHIVE.sha256"
