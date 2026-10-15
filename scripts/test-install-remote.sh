#!/usr/bin/env bash
# Regression test for packaging/install-remote.sh — OFFLINE, no network.
#
# Why this exists: the installer was broken against every published release and
# nothing caught it, because the only way anyone exercised it was to run it for
# real against GitHub (which installs a bundle and can touch the LaunchAgent).
# Two defects shipped that way:
#   * it selected the bare-binary `.tar.gz` (the only name matching
#     `macrdp`+`.tar.gz`) and then failed with "archive does not contain
#     macrdp.app";
#   * it fetched `${asset}.sha256`, which 404s on every release (release.yml
#     collapses those into SHA256SUMS and deletes them), so it silently
#     installed UNVERIFIED while claiming to verify.
# This script replays those cases against a stubbed `curl` and a fake release,
# so asset selection, checksum verification, the refusal to install unverified,
# and the atomic install are all asserted in about a second.
#
# Usage: scripts/test-install-remote.sh [--keep]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER="${INSTALLER:-$ROOT/packaging/install-remote.sh}"
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/macrdp-installer-test.XXXXXX")"
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT
[ "$KEEP" = 1 ] && echo "work dir: $WORK"

BIN="$WORK/bin"
FIXTURE="$WORK/fixture"
mkdir -p "$BIN" "$FIXTURE"

PASS=0
FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

# --- the fake release -------------------------------------------------------
# A fake macrdp.app (the installer only checks that the archive CONTAINS the
# bundle, then copies it) and a fake bare-binary tar.gz, laid out exactly like a
# published release: two archives + SHA256SUMS.
TAG="v0.0.1"
APP_ZIP="macrdp-$TAG-aarch64-apple-darwin-app.zip"
BARE_TGZ="macrdp-$TAG-aarch64-apple-darwin.tar.gz"

BUNDLE="$WORK/macrdp.app"
mkdir -p "$BUNDLE/Contents/MacOS"
printf '#!/bin/sh\necho fake\n' > "$BUNDLE/Contents/MacOS/macrdp"
chmod +x "$BUNDLE/Contents/MacOS/macrdp"
printf 'app-bundle-marker\n' > "$BUNDLE/Contents/marker"
ditto -c -k --keepParent "$BUNDLE" "$FIXTURE/$APP_ZIP"

BARE="$WORK/macrdp-$TAG-aarch64-apple-darwin"
mkdir -p "$BARE"
printf 'binary\n' > "$BARE/macrdp"
tar -C "$WORK" -czf "$FIXTURE/$BARE_TGZ" "$(basename "$BARE")"

BASE="https://api.github.com/repos/fake/fake/releases"
DL="https://github.com/fake/fake/releases/download/$TAG"
write_release_json() {
    cat > "$FIXTURE/release.json" <<EOF
{"tag_name":"$TAG","assets":[
 {"name":"$APP_ZIP","browser_download_url":"$DL/$APP_ZIP"},
 {"name":"$BARE_TGZ","browser_download_url":"$DL/$BARE_TGZ"}]}
EOF
}
write_release_json
(cd "$FIXTURE" && shasum -a 256 "$APP_ZIP" "$BARE_TGZ" > SHA256SUMS)

# --- the stub curl ----------------------------------------------------------
# Maps the two URL shapes the installer uses onto the fixture, and exits 22
# (curl's "HTTP error", which `-f` turns into a failure) for anything absent —
# so "not published" behaves exactly like a 404.
cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -H|--progress-bar) shift $([ "$1" = "-H" ] && echo 2 || echo 1) ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    */releases/latest|*/releases/tags/*) src="$MACRDP_TEST_FIXTURE/release.json" ;;
    */releases/download/*) src="$MACRDP_TEST_FIXTURE/${url##*/}" ;;
    *) src="" ;;
esac
[ -n "$src" ] && [ -f "$src" ] || exit 22
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
STUB
chmod +x "$BIN/curl"

# Run the installer from an ISOLATED copy: `install-remote.sh` only loads the
# LaunchAgent when `install-launchagent.sh` sits next to it, and the test must
# never touch the machine's agent. (This also mirrors the curl-pipe case.)
ISOLATED="$WORK/isolated"
mkdir -p "$ISOLATED"
cp "$INSTALLER" "$ISOLATED/install-remote.sh"

run_installer() { # run_installer <app_dir> [extra env assignments...]
    local app_dir="$1"; shift
    ( cd "$ISOLATED" && env PATH="$BIN:$PATH" MACRDP_TEST_FIXTURE="$FIXTURE" \
        MACRDP_APP_DIR="$app_dir" MACRDP_SKIP_LAUNCHAGENT=1 MACRDP_REPO=fake/fake \
        "$@" bash install-remote.sh ) >"$WORK/out.txt" 2>&1
}

echo "== 1. published layout: picks the app bundle and verifies SHA256SUMS =="
APP_DIR="$WORK/install1"
run_installer "$APP_DIR"
check "exit code" "$?" "0"
grep -q "downloading $APP_ZIP" "$WORK/out.txt" \
    && ok "downloaded the app archive (not the bare-binary tar.gz)" \
    || bad "downloaded the wrong asset: $(grep -m1 downloading "$WORK/out.txt")"
grep -q 'verifying SHA-256 (SHA256SUMS)' "$WORK/out.txt" && ok "verified against SHA256SUMS" || bad "no SHA256SUMS verification"
[ -f "$APP_DIR/macrdp.app/Contents/marker" ] && ok "installed the bundle" || bad "bundle not installed"

echo "== 2. tampered archive is refused =="
printf 'x' >> "$FIXTURE/$APP_ZIP"
run_installer "$WORK/install2"
[ "$?" -ne 0 ] && ok "non-zero exit on checksum mismatch" || bad "installed a tampered archive"
[ ! -d "$WORK/install2/macrdp.app" ] && ok "nothing installed" || bad "installed despite mismatch"
rm -rf "$WORK/install1"   # re-create a good archive below

echo "== 3. no published checksum: refused, unless explicitly allowed =="
ditto -c -k --keepParent "$BUNDLE" "$FIXTURE/$APP_ZIP"
rm -f "$FIXTURE/SHA256SUMS"
run_installer "$WORK/install3"
[ "$?" -ne 0 ] && ok "non-zero exit with no checksum" || bad "installed unverified by default"
grep -q 'refusing to install unverified' "$WORK/out.txt" && ok "explained the refusal" || bad "unclear refusal message"
[ ! -d "$WORK/install3/macrdp.app" ] && ok "nothing installed" || bad "installed despite refusal"
run_installer "$WORK/install3" MACRDP_ALLOW_UNVERIFIED=1
check "documented override installs" "$?" "0"
[ -f "$WORK/install3/macrdp.app/Contents/marker" ] && ok "override installed the bundle" || bad "override did not install"

echo "== 4. a release with only the bare-binary tar.gz fails loudly =="
(cd "$FIXTURE" && shasum -a 256 "$BARE_TGZ" > SHA256SUMS)
cat > "$FIXTURE/release.json" <<EOF
{"tag_name":"$TAG","assets":[
 {"name":"$BARE_TGZ","browser_download_url":"$DL/$BARE_TGZ"}]}
EOF
run_installer "$WORK/install4"
[ "$?" -ne 0 ] && ok "non-zero exit" || bad "installed something from a bare-binary release"
grep -q 'does not contain macrdp.app' "$WORK/out.txt" && ok "named the real problem" || bad "wrong error: $(tail -1 "$WORK/out.txt")"

echo "== 5. an existing install is replaced atomically =="
write_release_json
(cd "$FIXTURE" && shasum -a 256 "$APP_ZIP" "$BARE_TGZ" > SHA256SUMS)
run_installer "$WORK/install5"
check "first install" "$?" "0"
printf 'stale\n' > "$WORK/install5/macrdp.app/Contents/stale"
run_installer "$WORK/install5"
check "second install" "$?" "0"
[ ! -f "$WORK/install5/macrdp.app/Contents/stale" ] && ok "old bundle fully replaced (no leftovers)" || bad "stale file survived the swap"
ls "$WORK/install5"/.macrdp.app.* >/dev/null 2>&1 && bad "staging dir left behind" || ok "no staging/backup dirs left behind"

echo
if [ "$FAIL" -eq 0 ]; then
    echo "PASS — $PASS checks"
    exit 0
fi
echo "FAIL — $FAIL failed, $PASS passed (work dir kept: $WORK)"
exit 1
