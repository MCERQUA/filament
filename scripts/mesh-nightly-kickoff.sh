#!/usr/bin/env bash
# mesh-nightly-kickoff.sh — 03:15 UTC cron: start the nightly reflection round.
#
# Group decision 2026-04-24 — src-desktop's kickoff design accepted.
#
# Steps:
#   1. Ensure topic chatroom.nightly-reflection-<YYYY-MM-DD> exists.
#   2. Subscribe every registered agent (except host) to it.
#   3. Publish the kickoff event (CHAT:true, 45m deadline) to the topic.
#   4. Drop a KIND:task into each agent's inbox with REPLY_TO_TOPIC + DEADLINE.
#
# Idempotent on re-run. Each send is wrapped in `timeout 30` so one stuck
# agent cannot wedge the cron job (per code-quality review 2026-04-24).

set -euo pipefail

MESH_ROOT="${MESH_ROOT:-/opt/filament-mesh}"
export MESH_ROOT
# Host agent identity — required by mesh-event / mesh-send
export AGENT_URI="${AGENT_URI:-host@mesh}"

LOG="${MESH_ROOT}/logs/mesh-nightly-kickoff.log"
mkdir -p "$(dirname "$LOG")"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

DATE="$(date -u +%Y-%m-%d)"
TOPIC="chatroom.nightly-reflection-${DATE}"
TOPIC_SLUG="chatroom-nightly-reflection-${DATE}"  # how mesh-event slugifies the dir
DEADLINE="$(date -u -d '+45 min' +%Y-%m-%dT%H:%M:%SZ)"

BIN_DIR="$(cd "$(dirname "$0")/.." && pwd)/bin"
MESH_EVENT="${BIN_DIR}/mesh-event"
MESH_SEND="${BIN_DIR}/mesh-send"

log "kickoff start — topic=${TOPIC} deadline=${DEADLINE}"

# 1. Ensure topic + subscribers dir exist
mkdir -p "${MESH_ROOT}/mesh/EVENTS/${TOPIC_SLUG}/subscribers"

# 2. Subscribe every registered agent (except host) — idempotent via mesh-event subscribe
for reg in "${MESH_ROOT}/mesh/REGISTRY/"*.md; do
    [[ -f "$reg" ]] || continue
    agent="$(basename "$reg" .md)"
    case "$agent" in
        host|REGISTRY|"") continue ;;
    esac
    # Run as the target agent so their identity is on the subscriber record
    if ! AGENT_URI="${agent}@mesh" timeout 30 "$MESH_EVENT" subscribe "$TOPIC" \
         >/dev/null 2>&1; then
        log "WARN subscribe failed for ${agent}"
    fi
done

# 3. Publish kickoff event (as host@mesh, which is already exported above)
KICKOFF_BODY="$(cat <<BODY
# Nightly reflection — ${DATE}

Please post one reflection by **${DEADLINE}** (45 min window).

Template:
- What did I work on today?
- What's blocked / needs peer help?
- What am I picking up tomorrow?

Publish with: \`mesh-chat post nightly-reflection-${DATE}\`
Synthesis fires at 04:00 UTC; absentees are dead-lettered but there's no retry.
BODY
)"

if ! printf '%s\n' "$KICKOFF_BODY" \
   | timeout 30 "$MESH_EVENT" publish "$TOPIC" --chat --ttl 172800 >>"$LOG" 2>&1; then
    log "ERROR kickoff publish failed"
    exit 1
fi
log "kickoff event published"

# 4. Per-agent KIND:task with REPLY_TO_TOPIC + DEADLINE (carries the contract)
#    These land in the agent's inbox and wake their mesh-watch.
for reg in "${MESH_ROOT}/mesh/REGISTRY/"*.md; do
    [[ -f "$reg" ]] || continue
    agent="$(basename "$reg" .md)"
    case "$agent" in
        host|REGISTRY|"") continue ;;
    esac

    task_body="$(cat <<BODY
Nightly reflection for ${DATE}.

Deadline: ${DEADLINE}
Reply topic: ${TOPIC}

Publish one reflection to the topic via:
  echo "<body>" | mesh-chat post nightly-reflection-${DATE}

Then ack this task. Silence rule (§10.9) applies — do not narrate.
BODY
)"

    if ! printf '%s\n' "$task_body" \
       | timeout 30 "$MESH_SEND" \
           --to "${agent}@mesh" \
           --kind task \
           --subject "nightly-reflection-${DATE}" \
           --end-of-turn "${agent}@mesh — reflection expected by ${DEADLINE}" \
           >>"$LOG" 2>&1; then
        log "WARN task dispatch failed for ${agent}"
    fi
done

log "kickoff done"
