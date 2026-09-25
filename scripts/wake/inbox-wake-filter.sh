#!/usr/bin/env bash
# inbox-wake-filter.sh — decide which inbox arrivals are worth WAKING an agent for.
#
# WHY: a monitor that wakes the agent on EVERY new inbox file pays full model rates to be
# told nothing. Measured over one evening on a busy host inbox: 49 arrivals, 22 of them
# FYI-class (END-OF-TURN: none — session alerts, ticket announcements, receipts), each wake
# = several calls at a large cached context. Held FYIs are NOT lost: they stay in the inbox,
# a prompt-submit hook or the next digest counts them, and the next real turn reads them.
# Only a message that names this agent as OWING something should cost a wake.
#
# MODES
#   inbox-wake-filter.sh                 follow mode: watch the inbox (inotify), print one
#                                        "[mesh new] inbox: <file> (<verdict>)" line per
#                                        WAKE-class arrival on stdout. Built for a
#                                        persistent monitor that turns stdout lines into
#                                        agent notifications.
#   inbox-wake-filter.sh --decide FILE   print WAKE|HOLD + reason for one file; exit 0 on
#                                        WAKE, 1 on HOLD (for use as a filter by other tools)
#   inbox-wake-filter.sh --self-test     run the built-in fixtures
#
# ENV
#   AGENT_URI / WAKE_SELF_URI  this agent (default host@mesh). WAKE_SELF_ALIASES = more
#                         URIs that count as "me" (e.g. a second host session).
#   MESH_INBOX            inbox dir (default: /agent-desk/inbox in a container, else
#                         $MESH_ROOT/agents/<name>/inbox, MESH_ROOT default /mnt/agent-mesh)
#   WAKE_FILTER_STATE / WAKE_FILTER_PIDFILE / WAKE_FILTER_LOG
#                         default under ${XDG_STATE_HOME:-~/.local/state}/filament/
#   WAKE_HOLD_GLOBS       filename globs always held (space-separated), default
#                         "*event-chatroom-*" (room-event copies never owe a reply)
#   WAKE_SKIP_REGEX       filenames ignored entirely (default: \.dup|\.acked)
#   WAKE_CATCHUP_MAX      max MISSED lines emitted on start (default 8; the count line
#                         still reports the true total)
#
# RULES (first match wins)
#   HOLD  filename matches WAKE_HOLD_GLOBS
#   HOLD  selftest probe: subject slug "-selftest-" in the filename, or SPEAKING_AS: selftest
#   self-authored (AUTHOR = me): WAKE only with a body line "Urgency: critical|urgent"
#         (an ops alert routed to self); otherwise HOLD (a note-to-self for a later session)
#   HOLD  END-OF-TURN names a specific OTHER agent and not me (cc'd traffic)
#   HOLD  END-OF-TURN says none / no reply needed / nothing owed — unless KIND is one of
#         urgent|hitl|quarantine|dead-letter, which always wake
#   WAKE  KIND in urgent|task|question|blocker|hitl|rfc|delegate|decision|quarantine|dead-letter
#   WAKE  END-OF-TURN names me / "reply expected" / "please" / "your call" / GO/NO-GO
#   HOLD  END-OF-TURN none|no reply|FYI|nothing owed|completed-work
#   WAKE  no header at all, unreadable, or anything else (FAIL-NOISY: a broken header is
#         never a reason to go quiet)
set -u
SELF_URI="${WAKE_SELF_URI:-${AGENT_URI:-host@mesh}}"
SELF_NAME="${SELF_URI%@*}"
ALIASES="${WAKE_SELF_ALIASES:-}"
STATE_BASE="${XDG_STATE_HOME:-$HOME/.local/state}/filament"
if [ -n "${MESH_INBOX:-}" ]; then DIR="$MESH_INBOX"
elif [ -d /agent-desk/inbox ] && [ -z "${MESH_ROOT:-}" ]; then DIR=/agent-desk/inbox
else DIR="${MESH_ROOT:-/mnt/agent-mesh}/agents/$SELF_NAME/inbox"; fi
LOG="${WAKE_FILTER_LOG:-$STATE_BASE/wake-filter-$SELF_NAME.log}"
STATE="${WAKE_FILTER_STATE:-$STATE_BASE/wake-filter-$SELF_NAME.state}"
PIDF="${WAKE_FILTER_PIDFILE:-$STATE_BASE/wake-filter-$SELF_NAME.pid}"
HOLD_GLOBS="${WAKE_HOLD_GLOBS:-*event-chatroom-*}"
SKIP_RX="${WAKE_SKIP_REGEX:-\.dup|\.acked}"
CATCHUP_MAX="${WAKE_CATCHUP_MAX:-8}"

me_rx() {  # regex alternation of every URI that counts as me
    local r; r="$(printf '%s' "$SELF_URI" | sed 's/[.]/\\./g')"
    local a; for a in $ALIASES; do r="$r|$(printf '%s' "$a" | sed 's/[.]/\\./g')"; done
    printf '%s' "$r"
}

decide() {  # $1 = path ; prints "WAKE|HOLD <reason>"
    local f="$1" hdr eot kind author speaking base m1 m2 g
    # Settle + mtime bracket: a reader that runs before its writer finishes sees a chimera.
    m1=$(stat -c %Y "$f" 2>/dev/null || echo 0); sleep "${WAKE_SETTLE:-0.7}"
    m2=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    [ "$m1" != "$m2" ] && sleep 1.5
    hdr=$(head -n 12 "$f" 2>/dev/null) || { echo "WAKE unreadable"; return; }
    eot=$(printf '%s\n' "$hdr" | grep -m1 -i '^END-OF-TURN:' | cut -d: -f2- | tr -d '\r')
    kind=$(printf '%s\n' "$hdr" | grep -m1 -i '^KIND:' | awk '{print tolower($2)}')
    author=$(printf '%s\n' "$hdr" | grep -m1 -i '^AUTHOR:' | awk '{print $2}')
    speaking=$(printf '%s\n' "$hdr" | grep -m1 -i '^SPEAKING_AS:' | awk '{print tolower($2)}')
    base=$(basename "$f")
    for g in $HOLD_GLOBS; do
        # shellcheck disable=SC2254
        case "$base" in $g) echo "HOLD hold-glob ($g)"; return ;; esac
    done
    # SELFTEST. A probe fired down a REAL alarm channel had "selftest-" only in the
    # SUBJECT — where a human looks — while this filter keyed on KIND, so a fake alarm
    # woke the host on kind:blocker. The fix belongs HERE, not in the protocol: a new
    # "selftest" KIND would need every sender AND the receiver validator changed in the
    # right order, and a probe that silently QUARANTINES converts "my alert path is
    # broken" into "my alert path looks fine". Both markers below are already legal on
    # the wire. HOLD is logged, never silent, so a mis-marked probe is still auditable.
    case "$base" in *-selftest-*) echo "HOLD selftest (subject marker) kind=$kind author=$author"; return ;; esac
    [ "$speaking" = "selftest" ] && { echo "HOLD selftest (SPEAKING_AS) kind=$kind author=$author"; return; }

    # SELF-AUTHORED. An agent writes two kinds of record to itself and they must not share
    # a verdict: operational ALERTS auto-routed to it (disk, memory, board anomalies) —
    # these MUST wake — and NOTES-TO-SELF recording a finding for the next session, which
    # must not. Kind and end-of-turn are identical on both; the discriminator is a body line
    # the notifier always writes. A session that pages itself pays to be told what it just
    # decided, and that noise is how a real alert gets skimmed.
    if [ -n "$author" ] && printf '%s' "$author" | grep -qxE "$(me_rx)"; then
        if grep -qiE '^Urgency:[[:space:]]*(critical|urgent)' "$f" 2>/dev/null; then
            echo "WAKE self-authored ops alert (Urgency present)"; return
        fi
        echo "HOLD self-authored note-to-self (no Urgency line)"; return
    fi

    # CC'D TRAFFIC. Peers that cc this agent on desk-to-desk work tagged kind=blocker woke
    # it ~25 times in one morning, each END-OF-TURN naming ANOTHER agent. A message whose
    # END-OF-TURN names a specific other agent and not me is held; one that names me, says
    # nothing, or is unparseable still wakes.
    if printf '%s' "$eot" | grep -qE '[a-z0-9-]+@mesh' && ! printf '%s' "$eot" | grep -qiE "$(me_rx)"; then
        echo "HOLD cc-only (eot names $(printf '%s' "$eot" | grep -oE '[a-z0-9-]+@mesh' | head -1)) kind=$kind"; return
    fi
    # END-OF-TURN is the sender's own statement of what is owed; when it says NONE, the kind
    # does not override it — except for the four kinds that always wake.
    if printf '%s' "$eot" | grep -qiE '^\s*none\b|no reply needed|nothing owed'; then
        case "$kind" in
            urgent|hitl|quarantine|dead-letter) ;;
            *) echo "HOLD eot=none kind=$kind author=$author"; return ;;
        esac
    fi
    case "$kind" in
        urgent|task|question|blocker|hitl|rfc|delegate|decision|quarantine|dead-letter)
            echo "WAKE kind=$kind"; return ;;
    esac
    if printf '%s' "$eot" | grep -qiE "$(me_rx)|reply expected|please|your call|GO/NO-GO"; then
        echo "WAKE eot='$(printf '%s' "$eot" | cut -c1-60)'"; return
    fi
    if printf '%s' "$eot" | grep -qiE '^\s*none|no reply|FYI|nothing owed|completed-work'; then
        echo "HOLD kind=$kind eot='$(printf '%s' "$eot" | cut -c1-50)'"; return
    fi
    if [ -z "$eot" ] && [ -z "$kind" ]; then echo "WAKE no-header"; return; fi
    echo "WAKE default kind=$kind eot='$(printf '%s' "$eot" | cut -c1-50)'"
}

self_test() {
    local t fails=0 n=0; t="$(mktemp -d)"
    mk() { printf -- '---\nKIND: %s\nAUTHOR: %s\nEND-OF-TURN: %s\n%b---\nbody\n%s\n' "$2" "$3" "$4" "${6:-}" "${5:-}" > "$t/$1"; }
    mk 01-task.md               task         alice-desktop@mesh "$SELF_URI — reply expected"
    mk 02-fyi.md                message      alice-desktop@mesh "none — FYI"
    mk 03-blocker-cc.md         blocker      bob-desktop@mesh   "desk-1@mesh — reply expected"
    mk 04-urgent-none.md        urgent       bob-desktop@mesh   "none"
    mk 05-self-note.md          task         "$SELF_URI"        "none"
    mk 06-self-alert.md         task         "$SELF_URI"        "none" "Urgency: critical"
    mk 07-x-selftest-probe.md   blocker      bob-desktop@mesh   "$SELF_URI"
    mk 08-speaking.md           blocker      bob-desktop@mesh   "$SELF_URI" "" "SPEAKING_AS: selftest\n"
    mk 09-event-chatroom-x.md   task         bob-desktop@mesh   "$SELF_URI"
    mk 10-announce.md           announcement bob-desktop@mesh   "reply expected"
    printf 'no header at all\n' > "$t/11-noheader.md"
    printf -- '---\nKIND: blocker\nAUTHOR: bob-desktop@mesh\nEND-OF-TURN: none — thread closed\n---\n' > "$t/12-blocker-none.md"
    local want
    for want in "01-task.md WAKE" "02-fyi.md HOLD" "03-blocker-cc.md HOLD" "04-urgent-none.md WAKE" \
                "05-self-note.md HOLD" "06-self-alert.md WAKE" "07-x-selftest-probe.md HOLD" \
                "08-speaking.md HOLD" "09-event-chatroom-x.md HOLD" "10-announce.md WAKE" \
                "11-noheader.md WAKE" "12-blocker-none.md HOLD"; do
        set -- $want; n=$((n+1))
        got="$(WAKE_SETTLE=0 decide "$t/$1")"
        if [ "${got%% *}" = "$2" ]; then echo "ok    $1 -> $got"; else echo "FAIL  $1 -> $got (want $2)"; fails=$((fails+1)); fi
    done
    rm -rf "$t"
    echo "self-test: $((n-fails))/$n correct"; [ "$fails" = 0 ]
}

case "${1:-}" in
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    --self-test) self_test; exit $? ;;
    --decide) [ -n "${2:-}" ] || { echo "usage: --decide FILE" >&2; exit 64; }
              v="$(decide "$2")"; echo "$v"; [ "${v%% *}" = WAKE ]; exit $? ;;
    "") ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
esac

command -v inotifywait >/dev/null 2>&1 || { echo "inbox-wake-filter: inotifywait (inotify-tools) required" >&2; exit 69; }
[ -d "$DIR" ] || { echo "inbox-wake-filter: inbox not found: $DIR (set MESH_INBOX)" >&2; exit 66; }
mkdir -p "$(dirname "$LOG")" "$(dirname "$STATE")" "$(dirname "$PIDF")" 2>/dev/null || true

# ── SINGLE INSTANCE + CATCH-UP ────────────────────────────────────────────────────────
# `inotifywait -m` is PURELY reactive: it has no concept of "what arrived while I was not
# watching". Two things follow, and together they lose mail silently:
#   1. When the monitor that launched this expires, this script is NOT necessarily killed.
#      It keeps running as an orphan, consuming the inotify stream and deciding WAKE into a
#      stdout nobody reads. (Giveaway: the same filename decided TWICE in the log.)
#   2. So every WAKE decided between one monitor expiring and the next being armed is LOST
#      — not delayed. Measured: three real messages decided WAKE, nobody woken, and the
#      next monitor reported "no events", which is indistinguishable from a quiet inbox.
# Both halves are required; either alone still loses mail:
#   * kill any prior instance, so there is exactly one reader and no dead-pipe twin
#   * on start, replay anything that arrived since the last recorded decision
#
# ⚠️ Instance tracking is by PID FILE, never `pgrep -f <script name>`: that matches any
# command line CONTAINING the name — the launching shell, often a GRANDPARENT, and any
# terminal that typed it. On its first test run a pgrep-based version killed the very
# shell invoking it (exit 144, no output, no log). A PID file cannot self-match; liveness
# is checked in /proc and a stale file from a crashed instance is reaped, not believed.
if [ -r "$PIDF" ]; then
    old=$(cat "$PIDF" 2>/dev/null)
    case "$old" in
        ''|*[!0-9]*) : ;;
        *) if [ "$old" != "$$" ] && [ -d "/proc/$old" ] \
              && grep -qas 'inbox-wake-filter' "/proc/$old/cmdline" 2>/dev/null; then
               kill "$old" 2>/dev/null && echo "$(date -u +%FT%TZ) KILLED-ORPHAN pid=$old" >> "$LOG"
           fi ;;
    esac
fi
echo $$ > "$PIDF" 2>/dev/null || true
# Take our own pipeline down with us: killing this shell alone re-parents inotifywait and
# the read loop to init, where they keep running with nowhere to write. -P $$ = direct
# children only. Remove the pidfile ONLY if it is still ours — a successor writes its pid
# and then signals us, and an unconditional rm deleted the SUCCESSOR's pidfile.
RUN="$(mktemp -d "${TMPDIR:-/tmp}/wake-filter.XXXXXX")"
_reap() { pkill -TERM -P $$ 2>/dev/null; [ "$(cat "$PIDF" 2>/dev/null)" = "$$" ] && rm -f "$PIDF" 2>/dev/null; rm -rf "$RUN" 2>/dev/null; }
trap '_reap' EXIT
trap '_reap; exit 143' TERM INT HUP

# ORDER: arm the watch FIRST, replay the gap SECOND, consume the stream THIRD. Replaying
# before the watch is attached leaves a window in which a file that lands after the replay
# listed the directory but before inotify attached is seen by neither — the lost-mail bug
# again, one layer down. So the stream is buffered in the pipe until the replay is done,
# and anything the replay already decided is skipped when its event arrives.
# Backgrounded + `wait`: bash defers a trap until a FOREGROUND pipeline ends, and this one
# never ends — a TERM trap on a foreground pipeline makes the script unkillable.
inotifywait -m -e create -e moved_to --format '%f' "$DIR" 2>"$RUN/inotify.err" \
  | grep --line-buffered -E '\.md$' \
  | grep --line-buffered -vE "$SKIP_RX" \
  | { while [ ! -e "$RUN/caught-up" ]; do sleep 0.2; done
      while IFS= read -r name; do
        grep -qxF -- "$name" "$RUN/seen" 2>/dev/null && continue
        f="$DIR/$name"; [ -f "$f" ] || continue
        verdict=$(decide "$f")
        echo "$(date -u +%FT%TZ) $verdict $name" >> "$LOG"
        date +%s > "$STATE"   # advance the watermark per file, or every re-arm replays the backlog
        case "$verdict" in
            WAKE*) echo "[mesh new] inbox: $name  ($verdict)" ;;
            *) : ;;           # held: still in the inbox, counted by the next banner/digest
        esac
      done; } &
PIPE=$!
for _ in $(seq 1 50); do grep -q 'Watches established' "$RUN/inotify.err" 2>/dev/null && break; sleep 0.1; done
: > "$RUN/seen"

last=$(cat "$STATE" 2>/dev/null || echo 0)
case "$last" in ''|*[!0-9]*) last=0 ;; esac
if [ "$last" -gt 0 ]; then
    missed=0
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        b="$(basename "$f")"
        printf '%s' "$b" | grep -qE "$SKIP_RX" && continue
        printf '%s\n' "$b" >> "$RUN/seen"
        v=$(decide "$f")
        echo "$(date -u +%FT%TZ) CATCHUP $v $b" >> "$LOG"
        case "$v" in
            WAKE*) missed=$((missed+1))
                   [ "$missed" -le "$CATCHUP_MAX" ] && echo "[mesh new] inbox (MISSED while unwatched): $b  ($v)" ;;
        esac
    done <<EOF
$(find "$DIR" -maxdepth 1 -name '*.md' -newermt "@$last" -printf '%T@ %p\n' 2>/dev/null | sort -n | cut -d' ' -f2-)
EOF
    [ "$missed" -gt "$CATCHUP_MAX" ] && echo "[mesh new] ...and $((missed - CATCHUP_MAX)) further WAKE-class message(s) missed while unwatched — run mesh-recv"
    echo "$(date -u +%FT%TZ) CATCHUP-DONE missed_wake=$missed since=$last" >> "$LOG"
fi
date +%s > "$STATE"
touch "$RUN/caught-up"
wait "$PIPE"
