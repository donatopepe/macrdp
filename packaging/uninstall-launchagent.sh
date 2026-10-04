#!/usr/bin/env bash
# Remove the macrdp auto-start agent installed by packaging/install-launchagent.sh.
#
# What this does:
#   1. Unloads the com.clintcan.macrdp LaunchAgent (bootout, then clears the
#      disabled record so nothing resurrects it).
#   2. Removes ~/Library/LaunchAgents/com.clintcan.macrdp.plist — without this
#      the agent is loaded again at the next login, which is the usual
#      "I uninstalled it but it still starts" report.
#   3. Optionally removes the installed bundle ($APP_DIR/macrdp.app) with
#      --remove-app. It is NOT removed by default: it is a signed app whose
#      identity is what your Screen Recording / Accessibility grants are
#      attached to, so wiping it silently invalidates them and the next build
#      has to be re-granted.
#   4. Leaves config.env and the Keychain entry alone unless --purge-config /
#      --purge-keychain are given. config.env holds your feature toggles; the
#      Keychain entry holds your Mac account password and is shared with the
#      dist/ install path.
#
# The com.user.macrdp agent from dist/install.sh is a DIFFERENT install and is
# left alone — this script only reports it, because both bind :3390 and running
# them together is a known trap (docs/known-quirks.md).
#
# Usage: packaging/uninstall-launchagent.sh [--remove-app] [--purge-config]
#                                          [--purge-keychain] [--yes]

set -euo pipefail

BUNDLE_PREFIX="${BUNDLE_PREFIX:-com.clintcan}"
LABEL="$BUNDLE_PREFIX.macrdp"
APP_DIR="${APP_DIR:-/Applications}"
APP="$APP_DIR/macrdp.app"
SUPPORT="$HOME/Library/Application Support/macrdp"
CONFIG="$SUPPORT/config.env"
IDENTITY_FILE="$SUPPORT/installed-identity.txt"
PLIST_PATH="$HOME/Library/LaunchAgents/$LABEL.plist"
KEYCHAIN_SERVICE="macrdp"
OTHER_LABEL="com.user.macrdp"
REMOVE_APP=0
PURGE_CONFIG=0
PURGE_KEYCHAIN=0
ASSUME_YES=0

for arg in "$@"; do
    case "$arg" in
        --remove-app)     REMOVE_APP=1 ;;
        --purge-config)   PURGE_CONFIG=1 ;;
        --purge-keychain) PURGE_KEYCHAIN=1 ;;
        --yes|-y)         ASSUME_YES=1 ;;
        -h|--help)        sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

if [ "$ASSUME_YES" -eq 0 ]; then
    echo "About to remove the macrdp LaunchAgent ($LABEL):"
    [ -f "$PLIST_PATH" ] && echo "  - $PLIST_PATH"
    [ "$REMOVE_APP" -eq 1 ] && [ -d "$APP" ] && echo "  - $APP"
    [ "$PURGE_CONFIG" -eq 1 ] && echo "  - $CONFIG"
    [ "$PURGE_KEYCHAIN" -eq 1 ] && echo "  - Keychain entry $KEYCHAIN_SERVICE/$USER"
    [ "$REMOVE_APP" -eq 0 ] && [ -d "$APP" ] && \
        echo "  (keeping $APP — pass --remove-app to delete it; removing it"
    [ "$REMOVE_APP" -eq 0 ] && [ -d "$APP" ] && \
        echo "   invalidates your Screen Recording / Accessibility grants)"
    printf "Continue? [y/N] "
    read -r reply
    case "$reply" in
        y|Y|yes|YES) ;;
        *) echo "aborted"; exit 0 ;;
    esac
fi

# 1. Unload + forget any disabled record.
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    echo "==> Unloading $LABEL"
    launchctl bootout "gui/$(id -u)/$LABEL" || true
fi
launchctl disable "gui/$(id -u)/$LABEL" 2>/dev/null || true

# 2. Remove the plist, else it is loaded again at the next login.
if [ -f "$PLIST_PATH" ]; then
    echo "==> Removing $PLIST_PATH"
    rm -f "$PLIST_PATH"
fi
launchctl enable "gui/$(id -u)/$LABEL" 2>/dev/null || true

# 3. The app bundle: opt-in, because the grants hang off its code identity.
if [ "$REMOVE_APP" -eq 1 ] && [ -d "$APP" ]; then
    echo "==> Removing $APP"
    echo "    NOTE: the next build is a new code identity to macOS, so Screen"
    echo "    Recording and Accessibility must be re-granted once."
    rm -rf "$APP"
elif [ -d "$APP" ]; then
    echo "==> Keeping $APP (pass --remove-app to delete it)"
fi

# 4. Recorded identity + config + keychain: all opt-in.
if [ -f "$IDENTITY_FILE" ]; then
    echo "==> Removing $IDENTITY_FILE (the recorded code identity)"
    rm -f "$IDENTITY_FILE"
fi
if [ "$PURGE_CONFIG" -eq 1 ] && [ -f "$CONFIG" ]; then
    echo "==> Removing $CONFIG"
    rm -f "$CONFIG"
else
    echo "==> Keeping $CONFIG; pass --purge-config to remove it"
fi
if [ "$PURGE_KEYCHAIN" -eq 1 ]; then
    if security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" >/dev/null 2>&1; then
        echo "==> Purging Keychain entry $KEYCHAIN_SERVICE/$USER"
        security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$USER" || true
    fi
else
    echo "==> Keeping the Keychain entry ($KEYCHAIN_SERVICE/$USER); pass --purge-keychain to remove it"
fi

# Report — never touch — the other install path.
if launchctl print "gui/$(id -u)/$OTHER_LABEL" >/dev/null 2>&1; then
    echo
    echo "NOTE: $OTHER_LABEL is still loaded (the dist/install.sh path). That is"
    echo "      fine on its own — this script only removed $LABEL. Keep just one"
    echo "      of the two; they both bind :3390."
fi

echo
echo "Done. Verify nothing is listening on 3390:"
echo "  lsof -nP -iTCP:3390 -sTCP:LISTEN"
