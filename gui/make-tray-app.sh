#!/bin/bash
# Build the macrdp Controller menu-bar app: `swift build` the SwiftPM
# executable, wrap it in macrdpController.app (LSUIElement, signed), install it.
#
# Env overrides:
#   APP_DIR=/Applications              # install location (default /Applications)
#   CODESIGN_IDENTITY="-"             # "-" = ad-hoc; or a Developer ID name
#   AUTO_CREATE_LOCAL_CERT=1           # create local cert if missing (default 1)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GUI_DIR="$REPO_ROOT/gui"
APP_DIR="${APP_DIR:-/Applications}"
LOCAL_CERT_NAME="${LOCAL_CERT_NAME:-macrdp Local Code Signing}"
AUTO_CREATE_LOCAL_CERT="${AUTO_CREATE_LOCAL_CERT:-1}"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | grep -Fq "\"$LOCAL_CERT_NAME\""; then
    IDENTITY="$LOCAL_CERT_NAME"
elif [ "$AUTO_CREATE_LOCAL_CERT" = "1" ]; then
    "$REPO_ROOT/packaging/create-local-signing-cert.sh" "$LOCAL_CERT_NAME"
    IDENTITY="$LOCAL_CERT_NAME"
else
    IDENTITY="-"
fi

CODESIGN_KEYCHAIN_ARGS=()
if [ "$IDENTITY" != "-" ]; then
    CODESIGN_KEYCHAIN_ARGS=(--keychain "$HOME/Library/Keychains/login.keychain-db")
fi

APP_NAME="macrdpController.app"
# MUST match the BUNDLE_PREFIX used by packaging/{make-app,install-launchagent}.sh.
# The controller derives the server's LaunchAgent label by stripping ".controller"
# from its own bundle id at runtime, so this prefix decides which agent it drives.
BUNDLE_PREFIX="${BUNDLE_PREFIX:-com.clintcan}"
CONTROLLER_ID="$BUNDLE_PREFIX.macrdp.controller"

VERSION="$(grep -m1 '^version' "$REPO_ROOT/Cargo.toml" | cut -d'"' -f2)"
[ -n "$VERSION" ] || { echo "could not read version from Cargo.toml" >&2; exit 1; }

echo "==> macrdpController v$VERSION  (id: $CONTROLLER_ID, identity: $IDENTITY, install: $APP_DIR)"

echo "==> swift build -c release"
# SwiftUI's property wrappers are macros on macOS 26/27, so the controller needs
# the SwiftUI macro plugin — which only a FULL Xcode ships (the Command Line
# Tools do not, and the failure reads as a missing module rather than a missing
# toolchain). If xcode-select still points at the CLT but Xcode.app is sitting
# next to it, use it rather than making the operator remember DEVELOPER_DIR.
if [ -z "${DEVELOPER_DIR:-}" ] \
    && [ "$(xcode-select -p 2>/dev/null || true)" = "/Library/Developer/CommandLineTools" ] \
    && [ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/swift-build" ] \
    && [ ! -f "$(xcode-select -p 2>/dev/null || echo /nonexistent)/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
    echo "==> xcode-select points at the Command Line Tools, which cannot build SwiftUI"
    echo "    (no libSwiftUIMacros). Falling back to DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer"
    echo "    — switch it permanently with: sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer"
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
( cd "$GUI_DIR" && swift build -c release )
BIN="$GUI_DIR/.build/release/macrdptray"
[ -x "$BIN" ] || { echo "build produced no binary at $BIN" >&2; exit 1; }

STAGE="$REPO_ROOT/target/$APP_NAME"   # target/ is gitignored
echo "==> staging $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>macrdp Controller</string>
    <key>CFBundleDisplayName</key><string>macrdp Controller</string>
    <key>CFBundleIdentifier</key><string>$CONTROLLER_ID</string>
    <key>CFBundleExecutable</key><string>macrdptray</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

cp "$BIN" "$STAGE/Contents/MacOS/macrdptray"
chmod +x "$STAGE/Contents/MacOS/macrdptray"

# App icon (optional): packaging/macrdpController.png or packaging/icon.png.
ICON_SRC=""
for c in "$REPO_ROOT/packaging/macrdpController.png" "$REPO_ROOT/packaging/icon.png"; do
    [ -f "$c" ] && { ICON_SRC="$c"; break; }
done
if [ -n "$ICON_SRC" ]; then
    "$REPO_ROOT/packaging/make-icns.sh" "$ICON_SRC" "$STAGE/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$STAGE/Contents/Info.plist" \
        2>/dev/null || /usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon' "$STAGE/Contents/Info.plist"
    echo "==> app icon: $(basename "$ICON_SRC")"
fi

# Ad-hoc and local self-signed identities cannot use a secure timestamp;
# a real Developer ID must (notarization requires it).
if [ "$IDENTITY" = "-" ] || [ "$IDENTITY" = "$LOCAL_CERT_NAME" ]; then
    TS="--timestamp=none"
else
    TS="--timestamp"
fi

# Optional: embed + activate the macrdp Camera CoreMediaIO system extension
# (camera redirection Phase 3). CAMERA_EXTENSION=1 builds the extension via
# packaging/make-camera-extension.sh, embeds it in Contents/Library/
# SystemExtensions/, and signs THIS controller with the system-extension.install
# entitlement + a provisioning profile so OSSystemExtensionRequest can activate it.
# Unset (the normal controller build) → no extension, no entitlements, unchanged.
CTRL_ENT_ARG=""
if [ "${CAMERA_EXTENSION:-0}" = "1" ]; then
    [ "$IDENTITY" != "-" ] || echo "==> WARNING: ad-hoc camera-extension build won't activate (Developer ID + profiles needed)" >&2
    TEAM_ID="${TEAM_ID:-$(printf '%s' "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\)).*/\1/p')}"
    APP_GROUP="${APP_GROUP:-${TEAM_ID:-TEAMIDXXXX}.$BUNDLE_PREFIX.macrdp}"
    # Build + sign the extension bundle (its own entitlements/profile).
    OUT_DIR="$REPO_ROOT/target" TEAM_ID="${TEAM_ID:-}" APP_GROUP="$APP_GROUP" \
        CODESIGN_IDENTITY="$IDENTITY" BUNDLE_PREFIX="$BUNDLE_PREFIX" \
        "$REPO_ROOT/packaging/make-camera-extension.sh"
    # The extension bundle is named after its CFBundleIdentifier (required — see
    # make-camera-extension.sh); mirror that here.
    EXT_SRC="$REPO_ROOT/target/$BUNDLE_PREFIX.macrdp.controller.camera.systemextension"
    [ -d "$EXT_SRC" ] || { echo "extension not built at $EXT_SRC" >&2; exit 1; }
    mkdir -p "$STAGE/Contents/Library/SystemExtensions"
    cp -R "$EXT_SRC" "$STAGE/Contents/Library/SystemExtensions/"
    echo "==> embedded $(basename "$EXT_SRC")"
    # Controller entitlements: just system-extension.install (unsandboxed, no App
    # Group — the group lives only on the extension; see macrdp-controller.entitlements).
    CTRL_ENT_ARG="--entitlements $REPO_ROOT/packaging/macrdp-controller.entitlements"
    # Embed the controller's own provisioning profile (system-extension capability).
    if [ -n "${PROVISION_PROFILE:-}" ]; then
        [ -f "$PROVISION_PROFILE" ] || { echo "PROVISION_PROFILE not found: $PROVISION_PROFILE" >&2; exit 1; }
        cp "$PROVISION_PROFILE" "$STAGE/Contents/embedded.provisionprofile"
        echo "==> embedded controller provisioning profile"
    elif [ "$IDENTITY" != "-" ]; then
        echo "==> WARNING: CAMERA_EXTENSION=1 without PROVISION_PROFILE — activation needs the controller profile" >&2
    fi
fi

echo "==> codesign (hardened runtime, ts: $TS${CTRL_ENT_ARG:+, entitlements})"
codesign --force --options runtime $TS $CTRL_ENT_ARG "${CODESIGN_KEYCHAIN_ARGS[@]}" -s "$IDENTITY" "$STAGE/Contents/MacOS/macrdptray"
# NOTE: no --deep on the sign — the embedded .systemextension is already signed
# with its OWN entitlements; a --deep re-sign would strip them. Signing the outer
# bundle seals the pre-signed extension by reference.
codesign --force --options runtime $TS $CTRL_ENT_ARG "${CODESIGN_KEYCHAIN_ARGS[@]}" -s "$IDENTITY" "$STAGE"
codesign --verify --strict "$STAGE"

# Optional notarization (NOTARIZE=1, real Developer ID + NOTARY_PROFILE).
if [ "${NOTARIZE:-0}" = "1" ]; then
    [ "$IDENTITY" != "-" ] || { echo "NOTARIZE=1 needs a real CODESIGN_IDENTITY (not ad-hoc)" >&2; exit 1; }
    "$REPO_ROOT/packaging/notarize.sh" "$STAGE"
fi

echo "==> installing to $APP_DIR/$APP_NAME"
if ! mkdir -p "$APP_DIR" 2>/dev/null || [ ! -w "$APP_DIR" ]; then
    echo "    $APP_DIR not writable — re-run with sudo or set APP_DIR=\$HOME/Applications" >&2
    exit 1
fi
rm -rf "$APP_DIR/$APP_NAME"
cp -R "$STAGE" "$APP_DIR/$APP_NAME"
codesign --verify --strict "$APP_DIR/$APP_NAME"

echo
echo "Done. Installed: $APP_DIR/$APP_NAME"
echo "Note: it controls the LaunchAgent from packaging/ — run make-app.sh +"
echo "      install-launchagent.sh first if you haven't."

# 5. Register it as a login item, so the icon is there at every login instead of
#    only while the app happens to be running. A LaunchAgent (RunAtLoad +
#    KeepAlive) rather than SMAppService: that API wants the app in
#    /Applications and gives no "hide" affordance, and we already ship
#    LaunchAgents for everything else here. SETUP_LOGIN_ITEM=0 to skip.
if [ "${SETUP_LOGIN_ITEM:-1}" = "1" ]; then
    PLIST="$HOME/Library/LaunchAgents/$CONTROLLER_ID.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    echo "==> registering a login item at $PLIST"
    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$CONTROLLER_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_DIR/$APP_NAME/Contents/MacOS/macrdptray</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/macrdpController.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/macrdpController.err.log</string>
</dict>
</plist>
PLIST_EOF
    launchctl bootout "gui/$(id -u)/$CONTROLLER_ID" 2>/dev/null || true
    # Same EIO race install-launchagent.sh documents: `bootstrap` right after
    # `bootout` can fail with "Input/output error" (5) while launchd is still
    # tearing the old job down. Retry, and let the last attempt speak up.
    booted=0
    for _ in 1 2 3 4 5; do
        if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
            booted=1
            break
        fi
        sleep 1
    done
    [ "$booted" = 1 ] || launchctl bootstrap "gui/$(id -u)" "$PLIST" || {
        echo "    WARNING: could not load $CONTROLLER_ID; the icon appears only while the app runs." >&2
        echo "    Check: launchctl print gui/\$(id -u)/$CONTROLLER_ID" >&2
    }
    launchctl enable "gui/$(id -u)/$CONTROLLER_ID" 2>/dev/null || true
    if [ "$booted" = 1 ]; then
        echo "    loaded — the menu-bar icon is now persistent (quit it from the menu to hide)"
    fi
    echo "    Remove it again with: launchctl bootout gui/\$(id -u)/$CONTROLLER_ID && rm $PLIST"
fi
echo
echo "Launch it now:  open \"$APP_DIR/$APP_NAME\""
