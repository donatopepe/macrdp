#!/usr/bin/env bash
# Install macrdp as a per-user launchd agent that auto-starts at login.
#
# What this does:
#   1. Builds the release binary if needed.
#   2. Ad-hoc signs it so TCC grants persist across rebuilds.
#   3. Copies it to ~/.local/bin (override with $MACRDP_BIN_DIR).
#   4. Stores the Mac password in the macOS Keychain under service "macrdp".
#   5. Writes ~/Library/LaunchAgents/com.user.macrdp.plist with the
#      resolved binary path.
#   6. Loads the agent with launchctl.
#
# Re-run after `cargo build --release` to refresh the installed binary.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${MACRDP_BIN_DIR:-$HOME/.local/bin}"
BIN_PATH="$BIN_DIR/macrdp"
PLIST_PATH="$HOME/Library/LaunchAgents/com.user.macrdp.plist"
LABEL="com.user.macrdp"
KEYCHAIN_SERVICE="macrdp"

echo "==> Building release binary"
(cd "$REPO_ROOT" && cargo build --release)

# Signing identity. Ad-hoc ("-") keys the Screen Recording / Accessibility TCC
# grants to this exact cdhash, so they are REVOKED on every rebuild and the
# agent then crash-loops with `AsyncSCShareableContent::get failed` + exit 1
# under launchd (no GUI to prompt in). Same reason packaging/make-app.sh prefers
# a local self-signed certificate — keep the two paths consistent.
# Override with CODESIGN_IDENTITY="-", or set LOCAL_CERT_NAME to your own cert.
LOCAL_CERT_NAME="${LOCAL_CERT_NAME:-macrdp Local Code Signing}"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | grep -Fq "\"$LOCAL_CERT_NAME\""; then
    IDENTITY="$LOCAL_CERT_NAME"
else
    IDENTITY="-"
fi
if [ "$IDENTITY" = "-" ] && [ "${AUTO_CREATE_LOCAL_CERT:-1}" = "1" ] && [ -x "$REPO_ROOT/packaging/create-local-signing-cert.sh" ]; then
    echo "==> local signing identity not found; creating $LOCAL_CERT_NAME"
    "$REPO_ROOT/packaging/create-local-signing-cert.sh" "$LOCAL_CERT_NAME"
    IDENTITY="$LOCAL_CERT_NAME"
fi
# Switching identity (e.g. the first run after moving off ad-hoc) drops the
# existing TCC grants too — say so now rather than leaving a silent crash-loop.
if [ -f "$BIN_PATH" ]; then
    PREV_AUTHORITY="$(codesign -dvv "$BIN_PATH" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    [ -n "$PREV_AUTHORITY" ] || PREV_AUTHORITY="(ad-hoc)"
    if [ "$PREV_AUTHORITY" != "$IDENTITY" ]; then
        echo "==> NOTE: signing identity changes ($PREV_AUTHORITY -> $IDENTITY)."
        echo "    macOS ties Screen Recording / Accessibility to it, so you must"
        echo "    re-grant both in System Settings -> Privacy & Security, then"
        echo "    launchctl kickstart -k gui/\$(id -u)/$LABEL"
    fi
fi

echo "==> Signing (identity: $IDENTITY)"
codesign -s "$IDENTITY" --force "$REPO_ROOT/target/release/macrdp"

echo "==> Installing to $BIN_PATH"
mkdir -p "$BIN_DIR"
cp "$REPO_ROOT/target/release/macrdp" "$BIN_PATH"

# Keychain entry. add-generic-password -U updates if it exists.
if ! security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" >/dev/null 2>&1; then
    echo "==> Storing Mac password in Keychain (service=$KEYCHAIN_SERVICE, account=$USER)"
    echo -n "Mac password for $USER: "
    read -rs PW
    echo
    security add-generic-password -U -s "$KEYCHAIN_SERVICE" -a "$USER" -w "$PW"
    unset PW
else
    echo "==> Keychain entry already exists; leaving it alone"
fi

echo "==> Writing $PLIST_PATH"
sed "s|BINARY_PATH|$BIN_PATH|g" "$REPO_ROOT/dist/com.user.macrdp.plist.template" > "$PLIST_PATH"

# Unload first in case it was already loaded.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
echo "==> Loading agent"
launchctl bootstrap "gui/$UID" "$PLIST_PATH"

cat <<EOF

Installed. The agent will start automatically at login.

Verify:   launchctl print gui/$UID/$LABEL | head
Logs:     ~/Library/Logs/macrdp.log   (the server's own rotating log)
          /tmp/macrdp.out.log  /tmp/macrdp.err.log  (launchd stdout/stderr)
Stop:     launchctl bootout gui/$UID/$LABEL
Uninstall: dist/uninstall.sh
Restart:  launchctl kickstart -k gui/$UID/$LABEL

First-run TCC prompts (Screen Recording + Accessibility) will fire
against $BIN_PATH; grant them in System Settings → Privacy & Security
and run \`launchctl kickstart\` again. A launchd agent has no GUI to prompt
in, so until both are granted the agent exits 1 and is respawned every few
seconds — check /tmp/macrdp.err.log for 'Screen Recording permission?'.

Reachability: this template passes no --bind, so the agent listens on
127.0.0.1 only (LAN clients cannot connect). To expose it, add
    --bind 0.0.0.0:3390
to ProgramArguments in $PLIST_PATH and re-run \`launchctl kickstart -k\`.
EOF
