#!/usr/bin/env bash
# Remove the macrdp auto-start agent installed by dist/install.sh.
#
# What this does:
#   1. Unloads the com.user.macrdp LaunchAgent (bootout, then forget the
#      disabled record so RunAtLoad can't resurrect it).
#   2. Removes ~/Library/LaunchAgents/com.user.macrdp.plist — without this the
#      agent is back at the next login, which is the usual "I uninstalled it
#      but it still starts" report.
#   3. Removes the installed binary from ~/.local/bin (override with
#      $MACRDP_BIN_DIR). Pass --keep-binary to leave it in place.
#   4. Leaves the macrdp Keychain entry alone unless --purge-keychain is
#      given (it stores your Mac account password; the packaging/ path uses
#      the same entry).
#
# The com.clintcan.macrdp agent from packaging/install-launchagent.sh is a
# DIFFERENT install and is left alone — this script only reports it if it is
# loaded, because both bind :3390 and running them together is a known trap
# (see docs/known-quirks.md).
#
# Usage: dist/uninstall.sh [--keep-binary] [--purge-keychain] [--yes]

set -euo pipefail

LABEL="com.user.macrdp"
BIN_DIR="${MACRDP_BIN_DIR:-$HOME/.local/bin}"
BIN_PATH="$BIN_DIR/macrdp"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
KEYCHAIN_SERVICE="macrdp"
PKG_LABEL="${BUNDLE_PREFIX:-com.clintcan}.macrdp"
REMOVE_BINARY=1
PURGE_KEYCHAIN=0
ASSUME_YES=0

for arg in "$@"; do
    case "$arg" in
        --keep-binary)    REMOVE_BINARY=0 ;;
        --purge-keychain) PURGE_KEYCHAIN=1 ;;
        --yes|-y)         ASSUME_YES=1 ;;
        -h|--help)        sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

if [ "$ASSUME_YES" -eq 0 ]; then
    echo "About to remove the macrdp LaunchAgent ($LABEL):"
    [ -f "$PLIST_PATH" ] && echo "  - $PLIST_PATH"
    [ "$REMOVE_BINARY" -eq 1 ] && [ -f "$BIN_PATH" ] && echo "  - $BIN_PATH"
    [ "$PURGE_KEYCHAIN" -eq 1 ] && echo "  - Keychain entry $KEYCHAIN_SERVICE/$USER"
    printf "Continue? [y/N] "
    read -r reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) echo "aborted"; exit 0 ;;
    esac
fi

# 1. Unload. bootout also drops the job from the launchd cache; disable
#    additionally clears any persistent "disabled" record for the label.
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "==> Unloading $LABEL"
    launchctl bootout "gui/$(id -u)/$LABEL" || true
fi
launchctl disable "gui/$(id -u)/$LABEL" 2>/dev/null || true

# 2. Remove the plist, otherwise the agent is loaded again at the next login.
if [ -f "$PLIST_PATH" ]; then
    echo "==> Removing $PLIST_PATH"
    rm -f "$PLIST_PATH"
fi
launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true

# 3. Remove the binary.
if [ "$REMOVE_BINARY" -eq 1 ] && [ -f "$BIN_PATH" ]; then
    echo "==> Removing $BIN_PATH"
    rm -f "$BIN_PATH"
fi

# 4. Keychain entry: opt-in, since it holds a real account password and the
#    packaging/ agent authenticates with the same one.
if [ "$PURGE_KEYCHAIN" -eq 1 ]; then
    if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" >/dev/null 2>&1; then
        echo "==> Purging Keychain entry $KEYCHAIN_SERVICE/$USER"
        security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" || true
    fi
else
    echo "==> Keeping the Keychain entry ($KEYCHAIN_SERVICE/$USER); pass --purge-keychain to remove it"
fi

# Report — never touch — the other install path. Two agents on :3390 is the
# collision documented in docs/known-quirks.md.
if launchctl print "gui/$(id -u)/$PKG_LABEL" >/dev/null 2>&1; then
    echo
    echo "NOTE: $PKG_LABEL is still loaded (the packaging/ install). That is"
    echo "      fine on its own — this script only removed $LABEL. Keep just"
    echo "      one of the two; they both bind :3390."
fi

echo
echo "Done. Verify nothing is listening on 3390:"
echo "  lsof -nP -iTCP:3390 -sTCP:LISTEN"
