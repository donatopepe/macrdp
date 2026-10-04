#!/bin/bash
# Install + (re)load the macrdp LaunchAgent for the current user.
#
# Seeds ~/Library/Application Support/macrdp/config.env from the example on
# first run, renders the LaunchAgent plist from the template, and bootstraps it.
#
# Env overrides:
#   APP_DIR=/Applications     # where macrdp.app was installed (default /Applications)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$REPO_ROOT/packaging"
APP_DIR="${APP_DIR:-/Applications}"
# MUST match the BUNDLE_PREFIX used by make-app.sh (and gui/make-tray-app.sh),
# or the controller targets a different label than the agent installed here.
BUNDLE_PREFIX="${BUNDLE_PREFIX:-com.clintcan}"
LABEL="$BUNDLE_PREFIX.macrdp"
UID_NUM="$(id -u)"

APP="$APP_DIR/macrdp.app"
[ -d "$APP" ] || { echo "macrdp.app not found at $APP — run packaging/make-app.sh first" >&2; exit 1; }

# 1b. TCC identity guard. macOS keys the Screen Recording / Accessibility grants
#     to the app's designated requirement, so an identity change (a rebuilt
#     bundle signed with a different certificate, or a fallback to ad-hoc)
#     silently revokes the user's grants and macOS starts asking again. Record
#     the requirement at install time and shout if it ever moves.
check_identity() {
    local cur_dr prev_dr ident_file="$SUPPORT/installed-identity.txt"
    cur_dr="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
    [ -n "$cur_dr" ] || return 0
    prev_dr=""
    [ -f "$ident_file" ] && prev_dr="$(cat "$ident_file")"
    echo "==> designated requirement: $cur_dr"
    case "$cur_dr" in
        *cdhash*) echo "    WARNING: $APP is ad-hoc signed. Its identity is keyed to"
                  echo "    this exact cdhash, so Screen Recording / Accessibility are"
                  echo "    revoked on every rebuild. Rebuild with make-app.sh." ;;
    esac
    if [ -n "$prev_dr" ] && [ "$prev_dr" != "$cur_dr" ]; then
        echo "==> WARNING: code identity CHANGED since the last install"
        echo "      was: $prev_dr"
        echo "      now: $cur_dr"
        echo "    Re-grant Screen Recording AND Accessibility in System Settings"
        echo "    -> Privacy & Security, then: launchctl kickstart -k gui/$UID_NUM/$LABEL"
    fi
    printf '%s\n' "$cur_dr" > "$ident_file"
}

# 1. Seed config.env if absent.
SUPPORT="$HOME/Library/Application Support/macrdp"
mkdir -p "$SUPPORT" "$HOME/Library/Logs" "$HOME/Library/LaunchAgents"
CONFIG="$SUPPORT/config.env"
if [ ! -f "$CONFIG" ]; then
    cp "$PKG_DIR/config.env.example" "$CONFIG"
    echo "==> seeded $CONFIG (edit to taste)"
else
    echo "==> keeping existing $CONFIG"
fi

# 1b. Identity guard — after SUPPORT exists, so it can record the requirement.
check_identity

# 2. Render the LaunchAgent plist from the template.
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
sed -e "s#__LABEL__#$LABEL#g" -e "s#__APP_DIR__#$APP_DIR#g" -e "s#__HOME__#$HOME#g" \
    "$PKG_DIR/launchagent.plist.template" > "$PLIST"
# Keep operator-supplied RUST_LOG from config.env in LaunchAgent environment.
if grep -q '^RUST_LOG=' "$CONFIG"; then
    RUST_LOG_VALUE="$(grep '^RUST_LOG=' "$CONFIG" | tail -1 | cut -d= -f2- | sed 's/^\"//; s/\"$//')"
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:RUST_LOG string $RUST_LOG_VALUE" "$PLIST" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:RUST_LOG $RUST_LOG_VALUE" "$PLIST"
fi
echo "==> wrote $PLIST"

# 3. (Re)bootstrap the agent. `bootstrap` immediately after `bootout` can fail
#    with "Input/output error" (EIO, 5) while launchd is still tearing the old
#    job down — a race that otherwise leaves the agent UNloaded (server doesn't
#    come back). Retry a few times; the final attempt runs without suppressing
#    stderr so a genuine failure is surfaced (and aborts via set -e).
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
bootstrapped=0
for _ in 1 2 3 4 5; do
    if launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null; then
        bootstrapped=1
        break
    fi
    sleep 1
done
[ "$bootstrapped" = 1 ] || launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl enable "gui/$UID_NUM/$LABEL"
launchctl kickstart -k "gui/$UID_NUM/$LABEL"

# Verify launchd is executing the just-installed app path, not a stale binary
# or a different LaunchAgent label. This is intentionally a hard failure.
for _ in 1 2 3 4 5; do
    if launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null | grep -Fq "state = running"; then
        break
    fi
    sleep 1
done
launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null | grep -Fq "$APP/Contents/MacOS/macrdp" || {
    echo "LaunchAgent is not running the installed macrdp.app executable: $APP/Contents/MacOS/macrdp" >&2
    exit 1
}

echo
echo "Loaded $LABEL."
echo "  status:  launchctl print gui/$UID_NUM/$LABEL | grep -E 'state|pid'"
echo "  logs:    tail -f ~/Library/Logs/macrdp.log"
echo "  apply config change:  launchctl kickstart -k gui/$UID_NUM/$LABEL"
echo "  stop:    launchctl bootout gui/$UID_NUM/$LABEL"
