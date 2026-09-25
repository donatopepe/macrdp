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
#
# The script downloads a release archive and verifies its SHA-256 when the
# release publishes a matching .sha256 file. It never runs a downloaded binary
# before extraction, and it does not use sudo. macOS TCC permissions remain
# attached to the stable app bundle identity.
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
for a in assets:
    n=a["name"].lower()
    if n.endswith(".tar.gz") and ("macrdp" in n or "app" in n):
        print(a["browser_download_url"]); break
else:
    raise SystemExit("macrdp: release has no macrdp .tar.gz app asset")
PY
)"
ASSET_NAME="${ASSET_URL##*/}"
ARCHIVE="$TMP/$ASSET_NAME"
CHECKSUM_URL="${ASSET_URL}.sha256"
CHECKSUM="$TMP/$ASSET_NAME.sha256"

echo "==> macrdp $TAG"
echo "==> downloading $ASSET_NAME"
curl -fL --progress-bar "$ASSET_URL" -o "$ARCHIVE"
if curl -fsSL "$CHECKSUM_URL" -o "$CHECKSUM"; then
    echo "==> verifying SHA-256"
    (cd "$TMP" && shasum -a 256 -c "$(basename "$CHECKSUM")")
else
    echo "==> no release checksum published; continuing with HTTPS transport" >&2
fi

EXTRACT="$TMP/extract"
mkdir -p "$EXTRACT"
tar -xzf "$ARCHIVE" -C "$EXTRACT"
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
