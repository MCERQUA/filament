#!/usr/bin/env bash
# inbox-watch.sh — turn inbox arrivals into verified, tagged wakes of a live agent session.
#
# Agents running an interactive CLI in tmux do not poll their inbox: once a turn ends they
# idle at the prompt until something types into the pane. This is that something — made
# safe. It never reads, acks, or moves a message; the agent does that when woken.
#
# MODES
#   inbox-watch.sh --follow   event-driven (inotify). A PRODUCER enqueues arrivals; a single
#                             CONSUMER sends one coalesced wake at a time through mesh-wake
#                             and re-queues on failure. Run it next to the session (same
#                             host/container), e.g. from the session's service manager.
#   inbox-watch.sh --once     one cron-style pass (e.g. every 2 min from a HOST that nudges a
#                             pane elsewhere via WAKE_TMUX="docker exec -u app ctr tmux").
#                             Debounced on the inbox's newest mtime, with an actionability
#                             gate and a per-agent minimum interval.
#   inbox-watch.sh -h | --help
#
# ENV
#   AGENT_URI          whose inbox (default: host@mesh). Recorded in the ledger as sender.
#   MESH_INBOX         inbox dir (default as inbox-wake-filter.sh)
#   WAKE_TARGET        tmux target of the agent's pane (default: agent-mesh)
#   WAKE_FILTER        "1" (default) = only WAKE-class arrivals wake (inbox-wake-filter.sh
#                      --decide); "0" = every .md arrival wakes
#   WAKE_TEXT          wake text; "{n}" and "{files}" are substituted. Default:
#                      "new inbox file(s): {n} ({files}) — run mesh-recv, action what is
#                       yours, then ack"
#   WAKE_STATE_DIR     queue/lock/state dir (default ${XDG_STATE_HOME:-~/.local/state}/filament)
#   WATCH_MIN_INTERVAL --once: min seconds between wakes of the same agent (default 420)
#   WATCH_FRESH_SECS   --once: ignore arrivals older than this (default 1800)
#   plus mesh-wake's env (WAKE_TRANSCRIPT_DIR strongly recommended, WAKE_TMUX, ...)
#
# EXIT (--once): 0 woke or nothing to do · 1 wake attempted and failed (see log) · 64 usage
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wake-lib.sh
. "$HERE/wake-lib.sh"

SELF_URI="${AGENT_URI:-host@mesh}"; SELF_NAME="${SELF_URI%@*}"
if [ -n "${MESH_INBOX:-}" ]; then INBOX="$MESH_INBOX"
elif [ -d /agent-desk/inbox ] && [ -z "${MESH_ROOT:-}" ]; then INBOX=/agent-desk/inbox
else INBOX="${MESH_ROOT:-/mnt/agent-mesh}/agents/$SELF_NAME/inbox"; fi
TARGET="${WAKE_TARGET:-agent-mesh}"
SD="${WAKE_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/filament}"
Q="$SD/wake-queue-$SELF_NAME"; LOCK="$Q.lock"; LOG="$SD/inbox-watch-$SELF_NAME.log"
# (default kept in its own quoted variable: a literal "}" inside ${VAR:-...} ends the expansion)
DEFAULT_TEXT='new inbox file(s): {n} ({files}) — run mesh-recv, action what is yours, then ack'
TEXT_TMPL="${WAKE_TEXT:-$DEFAULT_TEXT}"
mkdir -p "$SD" 2>/dev/null; touch "$Q"
log() { printf '%s [inbox-watch] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

wake_text() {  # <n> <files...>
    local n="$1"; shift
    local files; files="$(printf '%s, ' "$@" | sed 's/, $//')"
    [ "${#files}" -gt 200 ] && files="${files:0:200}…"
    local t="${TEXT_TMPL//\{n\}/$n}"; printf '%s' "${t//\{files\}/$files}"
}

wants_wake() {  # <file>
    [ "${WAKE_FILTER:-1}" = 1 ] || return 0
    AGENT_URI="$SELF_URI" "$HERE/inbox-wake-filter.sh" --decide "$1" >/dev/null 2>&1
}

send_wake() {  # <origin> <text> ; returns mesh-wake's exit
    AGENT_URI="$SELF_URI" "$HERE/mesh-wake" --target "$TARGET" --origin "$1" --text "$2" >>"$LOG" 2>&1
}

case "${1:-}" in
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    --follow|--once) MODE="$1" ;;
    *) echo "usage: inbox-watch.sh --follow|--once  (see --help)" >&2; exit 64 ;;
esac
[ -d "$INBOX" ] || { echo "inbox-watch: inbox not found: $INBOX (set MESH_INBOX)" >&2; exit 66; }

# ═════════════════════════════ --once (cron poll) ═══════════════════════════════════
if [ "$MODE" = --once ]; then
    NUDGED="$SD/inbox-watch-$SELF_NAME.nudged_at"
    now=$(date +%s); last=$(cat "$NUDGED" 2>/dev/null || echo 0)
    # SIGNAL: newest mtime across inbox/ AND inbox/.read/ — archiving by `mv` preserves
    # mtime, so a fresh send advances this while routine archiving does not.
    newest=$(find "$INBOX" "$INBOX/.read" -maxdepth 1 -name '*.md' -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1)
    newest=${newest:-0}
    # ACTIONABILITY GATE: count ONLY what mesh-recv can return (inbox/, never .read/). A
    # wake whose prescribed action always returns "(no messages)" trains the agent to
    # ignore wakes — and "you have unread tasks, go" nudges it to invent work.
    mapfile -t fresh < <(find "$INBOX" -maxdepth 1 -name '*.md' -newermt "@$last" -printf '%f\n' 2>/dev/null | sort)
    actionable=$(find "$INBOX" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$actionable" -eq 0 ]; then
        [ "$newest" -gt "$last" ] && { log "newest advanced but inbox/ is EMPTY (archive event) — not waking"; echo "$now" > "$NUDGED"; }
        exit 0
    fi
    [ "$newest" -le "$last" ] && exit 0
    [ $(( now - newest )) -ge "${WATCH_FRESH_SECS:-1800}" ] && exit 0
    if [ "${#fresh[@]}" -eq 0 ]; then
        log "mtime advanced via .read/ only — not waking on an archive event"; echo "$now" > "$NUDGED"; exit 0
    fi
    wake=(); for f in "${fresh[@]}"; do wants_wake "$INBOX/$f" && wake+=("$f"); done
    if [ "${#wake[@]}" -eq 0 ]; then
        log "${#fresh[@]} fresh, all HOLD-class — not waking"; echo "$now" > "$NUDGED"; exit 0
    fi
    # The CLI QUEUES typed input while a turn runs, so a wake to a busy agent is safe —
    # but do not pile a second one onto one it already has queued.
    if wake_capture "$TARGET" | grep -q "Press up to edit queued messages"; then
        log "a message is already queued in the pane — not piling on"; echo "$now" > "$NUDGED"; exit 0
    fi
    if [ $(( now - last )) -lt "${WATCH_MIN_INTERVAL:-420}" ]; then
        log "woke $(( now - last ))s ago (<${WATCH_MIN_INTERVAL:-420}s) — holding"; exit 0
    fi
    send_wake inbox-watch "$(wake_text "${#wake[@]}" "${wake[@]}")"; rc=$?
    case $rc in
        0|4) echo "$now" > "$NUDGED"; log "woke (rc=$rc) for ${#wake[@]} file(s)"; exit 0 ;;
        *)   log "wake FAILED rc=$rc — will retry next pass"; exit 1 ;;
    esac
fi

# ═════════════════════════════ --follow (event-driven) ══════════════════════════════
# Wakes are SERIALIZED through a queue: the producer never types, it only enqueues; one
# consumer sends one wake at a time and verifies it before the next. Two arrivals during
# one verify used to STACK text in the input line (the second send-keys appends to the
# first's unsubmitted line, corrupting both). Queue edits hold a lock, so an arrival
# between the consumer's read and its truncate is never lost.
qlock() { exec 9>"$LOCK"; flock 9; }
qunlock() { flock -u 9; exec 9>&-; }

consumer() {
    local backoff files rc
    while :; do
        if [ ! -s "$Q" ]; then sleep 1; continue; fi
        qlock; mapfile -t files < "$Q"; : > "$Q"; qunlock
        # Coalesce: one wake per batch. The agent drains the whole inbox when woken; N wakes
        # for N files is N context loads for the same work.
        send_wake inbox-watch "$(wake_text "${#files[@]}" "${files[@]}")"; rc=$?
        case $rc in
            0) log "[sent] ${#files[@]} file(s) VERIFIED"; continue ;;
            4) log "[sent] ${#files[@]} file(s) CANNOT-TELL (no transcript surface) — not resending"; continue ;;
            2) backoff=10; log "[held] pane not ready/refused — re-queued" ;;
            3) backoff=30; log "[WEDGED] pane frozen — re-queued; the session needs a relaunch" ;;
            *) backoff=20; log "[STUCK] not submitted — re-queued" ;;
        esac
        # Re-queue at the HEAD, ahead of anything that arrived meanwhile, and back off so a
        # hard wedge does not spin the queue.
        qlock; { printf '%s\n' "${files[@]}"; cat "$Q"; } > "$Q.tmp" && mv "$Q.tmp" "$Q"; qunlock
        sleep "$backoff"
    done
}

command -v inotifywait >/dev/null 2>&1 || { echo "inbox-watch: inotifywait required for --follow" >&2; exit 69; }
consumer &
CPID=$!
trap 'kill $CPID 2>/dev/null; pkill -TERM -P $$ 2>/dev/null' EXIT
trap 'exit 143' TERM INT HUP
log "follow: inbox=$INBOX target=$TARGET queue=$Q"
inotifywait -m -q -e create -e moved_to --format '%f' "$INBOX" 2>/dev/null \
  | while IFS= read -r f; do
        case "$f" in *.md) ;; *) continue ;; esac
        if wants_wake "$INBOX/$f"; then
            qlock; printf '%s\n' "$f" >> "$Q"; qunlock
            log "[queued] $f"
        else
            log "[held] $f (HOLD-class)"
        fi
    done &
wait $!
