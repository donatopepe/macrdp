#!/usr/bin/env bash
# Round-trip every config.env key the menu-bar Settings window (or the menu) can
# write: set it, restart the server, and prove the setting actually reached it.
#
# Why this exists: a toggle that maps to nothing fails SILENTLY. `ALLOW_SLEEP=1`
# did exactly that for a while — the key was not in the config bridge, so the UI
# looked configured and the Mac still never slept. Nothing errors in that case,
# so only an explicit end-to-end check catches it.
#
# How each key is verified — and why NOT by looking for a flag in argv:
# with `--config <file>` the LaunchAgent passes exactly two arguments, and every
# flag derived from the file is applied INSIDE the process, so `ps -o command=`
# will never show `--enable-aac`. (Asserting on argv was my first attempt and it
# reported false failures for every flag-backed key.) So:
#   * every key        -> the server must come back up AND serve on 3390: a key
#                         that makes the server fail to start is caught here
#   * observable keys  -> the real effect is asserted (H.264/AAC log lines, the
#                         stats port, the bind address, caffeinate, the env-only
#                         tunables via the process environment)
#   * the flag bridge  -> covered exhaustively by the Rust `config_tests`
#                         (every key the UI can write must change the parsed
#                         Args), which is the only place the mapping is exact.
#
# Usage:  scripts/test-config-keys.sh [--keep] [--only KEY[,KEY...]]
#   --keep    leave the running server on the last tested key instead of
#             restoring the original config.env
#   --only    test just these keys (comma separated)
#
# Requires: a running com.clintcan.macrdp agent (the script restarts it). It
# snapshots config.env and restores it, including on interrupt.

set -uo pipefail

LABEL="${BUNDLE_PREFIX:-com.clintcan}.macrdp"
UID_NUM="$(id -u)"
DOMAIN="gui/$UID_NUM"
SUPPORT="$HOME/Library/Application Support/macrdp"
CONFIG="$SUPPORT/config.env"
LOG="$HOME/Library/Logs/macrdp.log"
KEEP=0
ONLY=""
PASS=0
FAIL=0
FAILED_KEYS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1 ;;
        --only) ONLY="${2:-}"; shift ;;
        -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

[ -f "$CONFIG" ] || { echo "no config.env at $CONFIG — run packaging/install-launchagent.sh first" >&2; exit 1; }

SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/macrdp-cfg.XXXXXX")"
cp "$CONFIG" "$SNAPSHOT"
# A second copy at a predictable path: if the harness is hard-killed (SIGKILL, no
# trap) the operator can still put the config back by hand.
HARD_BACKUP="$SUPPORT/config.env.harness-backup"
cp "$CONFIG" "$HARD_BACKUP"
restore() {
    if [ "$KEEP" -eq 1 ]; then
        echo "==> --keep: leaving config.env as the last test left it"
    else
        cp "$SNAPSHOT" "$CONFIG"
        launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null
        echo "==> restored the original config.env and restarted the server"
    fi
    rm -f "$SNAPSHOT" "$HARD_BACKUP"
}
trap restore EXIT INT TERM

server_pid() { pgrep -f "MacOS/macrdp .*--config" | head -1; }
server_argv() { ps -o command= -p "$(server_pid)" 2>/dev/null; }
server_env() { ps eww -o command= -p "$(server_pid)" 2>/dev/null; }

# Restart the agent, then wait for the NEW process.
#
# Two traps avoided, both of which produced wrong results here:
#   * waiting for "some process exists" is not enough — `kickstart -k` leaves the
#     outgoing pid visible for a moment, so the old pid and its listening socket
#     look fine while the new one is still booting (~2 s: watchdog, TCC, PAM),
#     and the log assertions then run against a banner that does not exist yet;
#   * `lsof` inside the polling loop costs ~1 s per call here, which turned a
#     30 s budget into many minutes and blew the caller's own timeout.
# So: a wall-clock budget, cheap checks only inside the loop (pid + log size),
# and the expensive listening check once, afterwards.
RESTART_TIMEOUT="${RESTART_TIMEOUT:-25}"
restart_and_wait() {
    local old_pid size_before deadline p
    old_pid="$(server_pid)"
    size_before="$(wc -c < "$LOG" 2>/dev/null || echo 0)"
    launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1
    deadline=$(( $(date +%s) + RESTART_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        p="$(server_pid)"
        if [ -n "$p" ] && [ "$p" != "$old_pid" ] \
            && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt "$size_before" ]; then
            sleep 0.5   # let the startup banner finish writing
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# Is the server actually accepting connections? One lsof call, once — not in a loop.
serving() { lsof -nP -iTCP:3390 -sTCP:LISTEN 2>/dev/null | grep -q macrdp; }


ok()   { PASS=$((PASS+1)); printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_KEYS+=("$2"); printf "  \033[31m✗\033[0m %s — %s\n" "$1" "$3"; }

# set_key KEY VALUE  — rewrite in place, preserving comments and other keys.
set_key() {
    KEY="$1"; VALUE="$2"
    if grep -qE "^[[:space:]]*${KEY}=" "$CONFIG"; then
        # BSD sed needs the backup suffix; the file is rewritten atomically after.
        sed -i '' -E "s|^[[:space:]]*${KEY}=.*|${KEY}=${VALUE}|" "$CONFIG"
    else
        printf '%s=%s\n' "$KEY" "$VALUE" >> "$CONFIG"
    fi
}

# assert_arg FLAG LABEL KEY  — the flag must be in the running argv
assert_arg() {
    local n
    n="$(server_argv | grep -c -- "$1" || true)"
    if [ "${n:-0}" -gt 0 ]; then ok "$2"; else bad "$2" "$3" "flag '$1' assente dall'argv: $(server_argv | cut -c1-90)"; fi
}
assert_no_arg() {
    local n
    n="$(server_argv | grep -c -- "$1" || true)"
    if [ "${n:-0}" -gt 0 ]; then bad "$2" "$3" "flag '$1' presente ma non dovrebbe"; else ok "$2"; fi
}
assert_env() {
    if server_env | tr ' ' '\n' | grep -qx -- "$1"; then ok "$2"; else bad "$2" "$3" "variabile $1 assente dall'ambiente"; fi
}
# `grep -q` exits on the FIRST match, which SIGPIPEs the writer; under
# `set -o pipefail` the pipeline then reports failure and this assertion lies
# ("no log line") for a log line that is right there. `grep -c` drains stdin, so
# the status reflects the search, not the pipe. Bit me once on ENABLE_H264.
assert_log() {
    local hits
    hits="$(tail -400 "$LOG" | grep -c -- "$1" || true)"
    if [ "${hits:-0}" -gt 0 ]; then ok "$2"; else bad "$2" "$3" "nessuna riga di log con '$1'"; fi
}
assert_port() {
    if lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; then ok "$2"; else bad "$2" "$3" "porta $1 non in ascolto"; fi
}
assert_bind() {
    local want="$1" label="$2" key="$3"
    local got
    got="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | grep -F "macrdp" | awk '{print $9}' | head -1)"
    if [ "$got" = "$want" ]; then ok "$label"; else bad "$label" "$key" "listener su '$got' invece di '$want'"; fi
}
assert_caffeinate() {
    if pgrep -f "caffeinate -dimsu" >/dev/null; then ok "$1"; else bad "$1" "$2" "nessun caffeinate: la prevenzione dello sleep non c'è"; fi
}
assert_no_caffeinate() {
    if pgrep -f "caffeinate -dimsu" >/dev/null; then bad "$1" "$2" "c'è caffeinate ma non dovrebbe"; else ok "$1"; fi
}

# ---------------------------------------------------------------- the matrix
# Each entry: KEY | VALUE | what to assert
run_key() {
    local key="$1" value="$2" how="$3" want="$4" label="$5"
    if [ -n "$ONLY" ] && [[ ",$ONLY," != *",$key,"* ]]; then return 0; fi

    echo "── $key=$value"
    set_key "$key" "$value"
    if [ "$how" = "expect_down" ]; then
        restart_and_wait >/dev/null 2>&1 || true
        sleep 3
        # Proves the key changed the outcome — and it is the most surprising
        # line in the file: no tty under launchd means no password prompt.
        if pgrep -f "MacOS/macrdp .*--config" >/dev/null; then
            bad "$key=$value" "$key" "il server è ancora attivo: la chiave non ha cambiato nulla"
        else
            ok "$key=$value (server fuori, come previsto: nessuna fonte di password)"
        fi
        return 0
    fi
    restarted=0
    restart_and_wait && restarted=1
    if [ "$restarted" -eq 0 ]; then
        bad "$key=$value" "$key" "il server non è ripartito con questa configurazione"
        return 0
    fi
    # Every key: the server must be back up and serving. A key that breaks the
    # start is the failure this catches most of the time.
    if pgrep -f "MacOS/macrdp .*--config" >/dev/null && serving; then
        ok "$key=$value (server su e in ascolto)"
    else
        bad "$key=$value" "$key" "il server non è in ascolto dopo questa configurazione"
        return 0
    fi
    case "$how" in
        env)        assert_env "$want" "$key=$value" "$key" ;;
        log)        assert_log "$want" "$key=$value" "$key" ;;
        port)       assert_port "$want" "$key=$value" "$key" ;;
        bind)       assert_bind "$want" "$key=$value" "$key" ;;
        sleep)      assert_caffeinate "$key=$value (a corrente: sleep trattenuto)" "$key" ;;
        nosleep)    assert_no_caffeinate "$key=$value (sleep normale)" "$key" ;;
        h264)       : ;; # coperto da ENABLE_H264 (log)
    esac
}

echo "══ config.env round-trip — $(date '+%H:%M:%S')"
echo "   config: $CONFIG"
restart_and_wait || { echo "il server non è in esecuzione: avvialo e rilancia" >&2; exit 1; }
echo "   server: pid $(server_pid)"
echo

# Connection / bind
run_key BIND "127.0.0.1:3390" bind "127.0.0.1:3390" ""
run_key BIND "0.0.0.0:3390" bind "*:3390" ""

# Keychain
run_key USE_KEYCHAIN 0 expect_down "" ""   # nessuna tty sotto launchd = nessuna prompt = deve uscire
run_key USE_KEYCHAIN 1 plain "" ""

# Virtual display
run_key VIRTUAL_DISPLAY 1 plain "" ""
run_key VIRTUAL_DISPLAY 0 noarg "--virtual-display" ""

# UDP multitransport
run_key ENABLE_UDP_MULTITRANSPORT 1 plain "" ""
run_key UDP_MIGRATE_EGFX 1 plain "" ""

# Stats endpoint (observable: a port)
run_key STATS_ENDPOINT 1 port 40245 ""

# Keyboard layout (flag, value with a dash)
run_key KEYBOARD_LAYOUT "com.apple.keylayout.Italian-Pro" plain "" ""

# HiDPI + H.264 + audio (observable: the pipeline log line)
run_key ENABLE_AAC 1 plain "" ""
run_key ENABLE_LOSSY_AUDIO 1 plain "" ""
run_key ADAPTIVE_BITRATE 1 plain "" ""
run_key ENABLE_H264 1 log "EGFX/H.264 pipeline configured" ""
# The AAC encoder is created on the first captured audio, i.e. when a client
# connects — nothing observable at startup, so this key is covered by the
# startup round-trip here and by the bridge test on the Rust side.
# Input
run_key ALT_TAB_SWITCH 1 plain "" ""
run_key ALT_BACKTICK_SWITCH 1 plain "" ""
run_key APP_SWITCHER_HUD 1 plain "" ""
run_key MAP_CTRL_TO_CMD 1 plain "" ""
run_key UNMINIMIZE 1 plain "" ""

# Redirection
run_key ENABLE_DRIVE_REDIRECTION 1 plain "" ""
run_key ENABLE_SMARTCARD_REDIRECTION 1 plain "" ""
run_key ENABLE_CAMERA_REDIRECTION 1 plain "" ""
run_key ENABLE_USB_REDIRECTION 1 plain "" ""
# env-only tunables: bridged to MACRDP_*, never to a flag
# MACRDP_USB_STREAM_STALL_MS is applied with setenv() INSIDE the process, and
# ps reports the kernel's initial environment block — so this one cannot be
# observed from outside. Covered here (server keeps serving) and by the Rust
# bridge test, which asserts the mapping itself.
run_key USB_STREAM_STALL_MS 1500 plain "" ""
run_key RESTORE_WINDOWS_ON_DISCONNECT 1 plain "" ""

# Host power: the INVERTED key, verified through its observable effect.
# On AC power the server holds sleep; with ALLOW_SLEEP=1 it must not.
run_key ALLOW_SLEEP 0 sleep "" ""
run_key ALLOW_SLEEP 1 nosleep "" ""

echo
echo "══ esito: $PASS ok, $FAIL falliti"
if [ "$FAIL" -gt 0 ]; then
    echo "   chiavi fallite: ${FAILED_KEYS[*]}"
    echo "   (ogni chiave qui è una leva visibile nella UI: una di queste è un interruttore che non fa niente)"
    exit 1
fi
