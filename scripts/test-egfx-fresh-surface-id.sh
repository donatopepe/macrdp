#!/usr/bin/env bash
# A/B the opt-in EGFX surface-id policy (config key `EGFX_FRESH_SURFACE_ID`)
# against the *live* server and client, and report what the log says about each
# connection.
#
# Why this exists
# ---------------
# mstsc (and the macOS client) retain EGFX surfaces BY ID for the whole lifetime
# of the client process and no-op a `CreateSurface` for an id they already hold.
# The stock per-connection auto-allocator always starts at 0, so a reconnect into
# a still-running client re-creates id 0, the client composites its stale
# retained surface, and the screen stays black with a live cursor. The
# blank-recovery reactivation and the drop/auto-reconnect path cannot always heal
# that (live 2026-10-15: 16/16 connections logged `surface_id=0`; the reactivation
# produced only a brief paint that relapsed; the storm guard tripped after 3
# drops). With `EGFX_FRESH_SURFACE_ID=1` each connection instead creates its
# surface at a persisted, never-before-used id, so the no-op cannot happen.
#
# This script only flips the key, restarts the agent, and reads the log — it does
# not install a build. The running binary must be one that has the flag
# (`macrdp --version`/the startup log tells you; the flag is a no-op on older
# builds, which is exactly why the log check below is mandatory).
#
# RESTARTING THE AGENT DROPS THE LIVE REMOTE SESSION. That is the point (a
# reconnect is what we are measuring), but do not run it while someone is using
# the machine remotely unless they agreed.
#
# Usage:
#   scripts/test-egfx-fresh-surface-id.sh on       [--seconds N] [--dry-run]
#   scripts/test-egfx-fresh-surface-id.sh off      [--seconds N] [--dry-run]
#   scripts/test-egfx-fresh-surface-id.sh restore  [--dry-run]
#   scripts/test-egfx-fresh-surface-id.sh status
#
#   on       snapshot config.env (once), set EGFX_FRESH_SURFACE_ID=1, restart,
#            watch the log for N seconds (default 300), print the verdict
#   off      same but the key is 0 (the stock auto-allocated id) — the control
#   restore  put the snapshot back and restart (the default end state)
#   status   print the current key value, snapshot, counter file and the last
#            few surface-id/blank lines; touches nothing
#
# The snapshot is `config.env.egfx-ab-snapshot` next to config.env, so `restore`
# works even after a reboot or a shell restart.

set -uo pipefail

LABEL="${BUNDLE_PREFIX:-com.clintcan}.macrdp"
UID_NUM="$(id -u)"
DOMAIN="gui/$UID_NUM"
SUPPORT="$HOME/Library/Application Support/macrdp"
CONFIG="$SUPPORT/config.env"
SNAPSHOT="$CONFIG.egfx-ab-snapshot"
LOG="$HOME/Library/Logs/macrdp.log"
KEY="EGFX_FRESH_SURFACE_ID"
COUNTER_DEFAULT="${TMPDIR:-/tmp}macrdp-egfx-next-surface-id"

MARKERS='EGFX fresh-surface-id mode ENABLED|EGFX: using a fresh \(never-used\) surface id|EGFX surface created \+ mapped|not presenting|blank recovery|giving up on automatic recovery|event="(accept|auth|fingerprint|disconnect)"|effective server configuration'

ACTION="${1:-}"; shift || true
SECONDS_TO_WATCH=300
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --seconds) SECONDS_TO_WATCH="${2:?--seconds needs a value}"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

die() { echo "error: $*" >&2; exit 1; }

[ -f "$CONFIG" ] || die "no config.env at $CONFIG"
[ -n "${ACTION:-}" ] || die "need one of: on | off | restore | status (try --help)"

current_value() {
    awk -F= -v k="$KEY" '$1==k {print $2}' "$CONFIG" | tail -1
}

# Set KEY=<value> in config.env, replacing the existing line or appending one.
# Deliberately python3, not sed: the value must never be interpreted as a regex,
# and an absent key must be appended rather than silently ignored.
set_key() {
    python3 - "$CONFIG" "$KEY" "$1" <<'PY'
import sys
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().split("\n")
out, seen = [], False
for line in lines:
    if line.split("=", 1)[0] == key:
        out.append(f"{key}={value}")
        seen = True
    else:
        out.append(line)
if not seen:
    # Append after the last non-empty line so the file stays tidy.
    while out and out[-1] == "":
        out.pop()
    out.append(f"{key}={value}")
    out.append("")
open(path, "w").write("\n".join(out))
PY
}

restart_agent() {
    if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        die "agent $DOMAIN/$LABEL is not loaded — start macrdp first (or install it)"
    fi
    launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 || die "launchctl kickstart failed"
    # Wait for the port to answer again, up to ~20 s.
    for _ in $(seq 1 40); do
        if nc -z 127.0.0.1 3390 >/dev/null 2>&1; then return 0; fi
        sleep 0.5
    done
    die "server did not come back on 127.0.0.1:3390 after the restart — check $LOG"
}

watch_log() {
    local secs="$1" tmp
    tmp="$(mktemp -t macrdp-egfx-ab)"
    # Snapshot the byte offset so we only report this window's lines.
    local start_size
    start_size="$(wc -c <"$LOG" | tr -d ' ')"
    tail -c +"$((start_size + 1))" -f "$LOG" >"$tmp" 2>/dev/null &
    local tail_pid=$!
    echo "watching $LOG for ${secs}s — connect/reconnect the client now (do NOT close its window unless the log says to)"
    sleep "$secs"
    kill "$tail_pid" 2>/dev/null
    wait "$tail_pid" 2>/dev/null
    grep -E "$MARKERS" "$tmp" | sed 's/^/  /' || echo "  (no matching log lines)"
    echo
    echo "== verdict =="
    if ! grep -qE 'EGFX fresh-surface-id mode ENABLED' "$tmp"; then
        echo "  NOTE: no 'fresh-surface-id mode ENABLED' line — the running build predates the flag,"
        echo "        or --config did not carry $KEY. The A/B would be meaningless."
    fi
    local ids blanks
    ids="$(grep -oE 'surface_id=[0-9]+' "$tmp" | sort -u | tr '\n' ' ')"
    blanks="$(grep -cE 'not presenting' "$tmp")"
    echo "  surface ids used this window: ${ids:-none}"
    echo "  blank-detector warnings:      $blanks"
    rm -f "$tmp"
}

case "$ACTION" in
    status)
        echo "key                 : $KEY=$(current_value || echo '(unset)')"
        echo "snapshot            : $([ -f "$SNAPSHOT" ] && echo "$SNAPSHOT" || echo '(none)')"
        echo "counter file        : ${MACRDP_EGFX_SURFACE_ID_FILE:-$COUNTER_DEFAULT}$([ -f "${MACRDP_EGFX_SURFACE_ID_FILE:-$COUNTER_DEFAULT}" ] && echo " = $(cat "${MACRDP_EGFX_SURFACE_ID_FILE:-$COUNTER_DEFAULT}")" || echo ' (absent)')"
        echo "effective config    : $(grep -c 'effective server configuration' "$LOG") startup lines in the log; last:"
        grep 'effective server configuration' "$LOG" | tail -1 | sed 's/^/  /'
        echo "recent surface/blank:"
        grep -E 'fresh-surface-id mode ENABLED|surface created \+ mapped|not presenting|giving up on automatic recovery' "$LOG" | tail -6 | sed 's/^/  /'
        exit 0 ;;
    on|off)
        VALUE=1; [ "$ACTION" = off ] && VALUE=0
        echo "current: $KEY=$(current_value || echo unset) -> $VALUE"
        if [ "$DRY_RUN" = 1 ]; then
            echo "dry run: would snapshot $CONFIG to $SNAPSHOT (if absent), set $KEY=$VALUE, restart $DOMAIN/$LABEL, watch ${SECONDS_TO_WATCH}s"
            exit 0
        fi
        [ -f "$SNAPSHOT" ] || { cp -p "$CONFIG" "$SNAPSHOT" || die "could not write $SNAPSHOT"; echo "snapshot: $SNAPSHOT"; }
        set_key "$VALUE" || die "could not edit $CONFIG"
        restart_agent
        sleep 3
        grep 'effective server configuration' "$LOG" | tail -1 | sed 's/^/  /'
        watch_log "$SECONDS_TO_WATCH"
        echo
        echo "when done: $0 restore   (puts the original config.env back and restarts)"
        exit 0 ;;
    restore)
        [ -f "$SNAPSHOT" ] || die "no snapshot at $SNAPSHOT — nothing to restore"
        echo "restoring $CONFIG from $SNAPSHOT"
        if [ "$DRY_RUN" = 1 ]; then echo "dry run: would restore and restart"; exit 0; fi
        cp -p "$SNAPSHOT" "$CONFIG" || die "restore failed"
        rm -f "$SNAPSHOT"
        restart_agent
        sleep 3
        grep 'effective server configuration' "$LOG" | tail -1 | sed 's/^/  /'
        exit 0 ;;
    -h|--help|help) sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown action '$ACTION' (try --help)" ;;
esac
