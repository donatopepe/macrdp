#!/usr/bin/env bash
# Install the latest signed macrdp.app from a GitHub Release.
#
# Usage (interactive, recommended):
#   curl -fsSL https://raw.githubusercontent.com/donatopepe/macrdp/main/packaging/install-remote.sh | bash
#
# Optional environment:
#   MACRDP_VERSION=v0.9.7      exact release tag; default: latest
#   MACRDP_APP_DIR=$HOME/Applications
#   MACRDP_REPO=owner/repo     default: donatopepe/macrdp
#   MACRDP_SKIP_LAUNCHAGENT=1  download/install app only
#   MACRDP_ALLOW_UNVERIFIED=1  install even when the release publishes no checksum
#
# The script downloads the APP-BUNDLE archive from a release (not the bare-binary
# .tar.gz, which contains no macrdp.app), verifies it against the release's
# published `SHA256SUMS` (falling back to a per-asset `.sha256`, and refusing to
# install unverified unless MACRDP_ALLOW_UNVERIFIED=1), then installs it
# atomically. It never runs a downloaded binary before extraction, and it does
# not use sudo. macOS TCC permissions remain attached to the stable app bundle
# identity.
#
# Safe rehearsal of this path without touching the real install (downloads the
# newest published release into a throwaway dir, no LaunchAgent):
#   mkdir -p /tmp/macrdp-rehearsal && cp packaging/install-remote.sh /tmp/macrdp-rehearsal/
#   (cd /tmp/macrdp-rehearsal && MACRDP_APP_DIR=/tmp/macrdp-rehearsal/app \
#      MACRDP_SKIP_LAUNCHAGENT=1 bash install-remote.sh)
set -euo pipefail

REPO="${MACRDP_REPO:-donatopepe/macrdp}"
APP_DIR="${MACRDP_APP_DIR:-$HOME/Applications}"
VERSION="${MACRDP_VERSION:-latest}"
API="https://api.github.com/repos/$REPO/releases"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/macrdp-install.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

command -v curl >/dev/null || { echo "macrdp: curl is required" >&2; exit 1; }
command -v ditto >/dev/null || { echo "macrdp: ditto is required on macOS" >&2; exit 1; }
command -v shasum >/dev/null || { echo "macrdp: shasum is required" >&2; exit 1; }

if [ "$VERSION" = latest ]; then
    RELEASE_JSON="$TMP/release.json"
    curl -fsSL -H 'Accept: application/vnd.github+json' "$API/latest" -o "$RELEASE_JSON"
else
    RELEASE_JSON="$TMP/release.json"
    curl -fsSL -H 'Accept: application/vnd.github+json' "$API/tags/$VERSION" -o "$RELEASE_JSON"
fi

TAG="$(python3 - "$RELEASE_JSON" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["tag_name"])
PY
)"
ASSET_URL="$(python3 - "$RELEASE_JSON" <<'PY'
import json, sys
assets=json.load(open(sys.argv[1])).get("assets", [])
named=[(a["name"], a["browser_download_url"]) for a in assets]

# Prefer the APP-BUNDLE archive. The bare-binary .tar.gz also matches
# "macrdp"+".tar.gz" and installing it fails with "archive does not contain
# macrdp.app" — while the app asset is named `…-app.zip`.
def rank(name):
    n = name.lower()
    if not (n.endswith(".zip") or n.endswith(".tar.gz")):
        return None
    is_app = "app" in n
    is_zip = n.endswith(".zip")
    return 0 if is_app and is_zip else 1 if is_app else 2 if is_zip else 3

candidates = sorted((rank(n), n, u) for n, u in named if rank(n) is not None)
if not candidates:
    raise SystemExit("macrdp: release has no .zip/.tar.gz archive")
print(candidates[0][2])
PY
)"
ASSET_NAME="${ASSET_URL##*/}"
ARCHIVE="$TMP/$ASSET_NAME"

echo "==> macrdp $TAG"
echo "==> downloading $ASSET_NAME"
curl -fL --progress-bar "$ASSET_URL" -o "$ARCHIVE"

# Verify against the release's PUBLISHED checksums. `SHA256SUMS` is what
# release.yml actually ships — the per-asset `…tar.gz.sha256` files are
# collapsed into it and deleted before the release is created — so checking only
# `${ASSET_URL}.sha256` (the original behaviour) 404'd on every release and the
# installer silently fell back to HTTPS. Verification is required unless the
# operator explicitly opts out with MACRDP_ALLOW_UNVERIFIED=1.
verify_archive() {
    if curl -fsSL "${ASSET_URL%/*}/SHA256SUMS" -o "$TMP/SHA256SUMS" \
        && grep -F "  $ASSET_NAME" "$TMP/SHA256SUMS" > "$TMP/entry.sha256" \
        && [ -s "$TMP/entry.sha256" ]; then
        echo "==> verifying SHA-256 (SHA256SUMS)"
        (cd "$TMP" && shasum -a 256 -c entry.sha256)
        return 0
    fi
    if curl -fsSL "${ASSET_URL}.sha256" -o "$TMP/entry.sha256" \
        && [ -s "$TMP/entry.sha256" ]; then
        echo "==> verifying SHA-256 ($ASSET_NAME.sha256)"
        (cd "$TMP" && shasum -a 256 -c entry.sha256)
        return 0
    fi
    if [ "${MACRDP_ALLOW_UNVERIFIED:-0}" = 1 ]; then
        echo "==> WARNING: no published checksum for $ASSET_NAME; continuing unverified" >&2
        return 0
    fi
    echo "macrdp: no published checksum for $ASSET_NAME — refusing to install unverified." >&2
    echo "        Re-run with MACRDP_ALLOW_UNVERIFIED=1 to override (not recommended)." >&2
    return 1
}
verify_archive

EXTRACT="$TMP/extract"
mkdir -p "$EXTRACT"
case "$ASSET_NAME" in
    *.zip)    ditto -x -k "$ARCHIVE" "$EXTRACT" ;;
    *.tar.gz) tar -xzf "$ARCHIVE" -C "$EXTRACT" ;;
    *)        echo "macrdp: unsupported archive type: $ASSET_NAME" >&2; exit 1 ;;
esac
APP="$(find "$EXTRACT" -maxdepth 4 -type d -name macrdp.app -print -quit)"
[ -n "$APP" ] || { echo "macrdp: archive does not contain macrdp.app" >&2; exit 1; }

mkdir -p "$APP_DIR"
DEST="$APP_DIR/macrdp.app"
STAGE="$APP_DIR/.macrdp.app.$$.new"
rm -rf "$STAGE"
ditto "$APP" "$STAGE"
if [ -d "$DEST" ]; then
    mv "$DEST" "$APP_DIR/.macrdp.app.$$.old"
fi
mv "$STAGE" "$DEST"
rm -rf "$APP_DIR/.macrdp.app.$$.old"
echo "==> installed $DEST"

if [ "${MACRDP_SKIP_LAUNCHAGENT:-0}" != 1 ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -x "$SCRIPT_DIR/install-launchagent.sh" ]; then
        APP_DIR="$APP_DIR" "$SCRIPT_DIR/install-launchagent.sh"
    else
        echo "==> app installed; run packaging/install-launchagent.sh from a macrdp checkout to enable launchd"
    fi
fi

echo
cat <<EOF
Installed macrdp $TAG.
Next: grant Screen Recording and Accessibility to macrdp.app in System Settings.
For a LAN/VPN server set BIND=0.0.0.0:3390 in ~/Library/Application Support/macrdp/config.env.
EOF
