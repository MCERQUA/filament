#!/usr/bin/env bash
# scheduled-wake.sh — at a scheduled time, make the LIVE agent session do something itself
# (attend a meeting, post a reflection), unless it already did.
#
# WHY: an agent that runs in tmux nearly all the time can still miss a scheduled duty — not
# because the session is down, but because nothing POKED it. Reminders that only land in the
# inbox surface through a monitor; if that monitor is not armed, the live session never sees
# them and silently no-shows. This wakes the session DIRECTLY, and demotes any headless
# stand-in to a true fallback that runs only when the session is genuinely gone.
#
# USAGE
#   scheduled-wake.sh --target T --origin O (--prompt TEXT | --prompt-file F)
#                     [--done-file F --done-regex R] [--fallback "CMD"]
#
#   --done-file/--done-regex  idempotence: if F exists and matches R, the duty is done —
#                             never nag a session that already showed up (accept every
#                             sign-off form the session actually writes; attendance is
#                             attendance).
#   --fallback CMD            run (via bash -c) ONLY when the target session does not exist.
#                             That case is itself an anomaly and is logged as one.
#
# Cron example:  15 3 * * *  scheduled-wake.sh --target host-mesh --origin meeting-kickoff \
#                    --prompt-file ~/prompts/kickoff.txt --done-file "$MESH_ROOT/mesh/..." \
#                    --done-regex 'Host judgment layer'
#
# EXIT: mesh-wake's exit when a wake was sent (0 = VERIFIED); 0 when already done; the
#       fallback's exit when the session was absent; 64 usage.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wake-lib.sh
. "$HERE/wake-lib.sh"
export PATH="/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"   # cron strips PATH; tmux lives in /usr/bin

TARGET=""; ORIGIN=""; PROMPT=""; DONE_FILE=""; DONE_RX=""; FALLBACK=""
while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --origin) ORIGIN="$2"; shift 2 ;;
        --prompt) PROMPT="$2"; shift 2 ;;
        --prompt-file) PROMPT="$(cat "$2")"; shift 2 ;;
        --done-file) DONE_FILE="$2"; shift 2 ;;
        --done-regex) DONE_RX="$2"; shift 2 ;;
        --fallback) FALLBACK="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "scheduled-wake: unknown arg $1" >&2; exit 64 ;;
    esac
done
[ -n "$TARGET" ] && [ -n "$ORIGIN" ] && [ -n "$PROMPT" ] || { echo "scheduled-wake: --target, --origin and a prompt are required" >&2; exit 64; }
LOG="${WAKE_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/filament/wake.log}"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { echo "$(date -u +%FT%TZ) [scheduled-wake:$ORIGIN] $*" >> "$LOG"; }

if [ -n "$DONE_FILE" ] && [ -f "$DONE_FILE" ] && grep -qE "${DONE_RX:-.}" "$DONE_FILE"; then
    log "already done (marker present in $DONE_FILE) — no wake"; exit 0
fi

if wt has-session -t "${TARGET%%:*}" 2>/dev/null; then
    "$HERE/mesh-wake" --target "$TARGET" --origin "$ORIGIN" --text "$PROMPT"; rc=$?
    log "woke $TARGET rc=$rc"
    exit $rc
fi

log "ANOMALY: session ${TARGET%%:*} not found — the live agent is down"
if [ -n "$FALLBACK" ]; then
    bash -c "$FALLBACK" >>"$LOG" 2>&1; rc=$?
    log "fallback exit=$rc"; exit $rc
fi
exit 2
