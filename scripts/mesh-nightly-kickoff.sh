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

# OFFLINE eligibility per josh's REFLECTION-PROTOCOL.md §Phase 1:
#   skip any agent whose heartbeat is > 600s old at kickoff time and
#   dead-letter them immediately (they can't respond before 04:00Z anyway).
# Quarantine state is NOT used for eligibility — synthesis handles validation.
HEARTBEAT_DIR="${MESH_ROOT}/mesh/HEARTBEAT"
NOW_EPOCH="$(date -u +%s)"
OFFLINE_THRESHOLD=600

is_offline() {
    local agent="$1"
    local hb="${HEARTBEAT_DIR}/${agent}.last"
    [[ -f "$hb" ]] || return 0  # no heartbeat file → offline
    local mt
    mt="$(stat -c %Y "$hb" 2>/dev/null || echo 0)"
    (( NOW_EPOCH - mt > OFFLINE_THRESHOLD ))
}

dead_letter_offline() {
    local agent="$1"
    local dl_dir="${MESH_ROOT}/mesh/DEAD_LETTER/${agent}"
    mkdir -p "$dl_dir"
    cat > "${dl_dir}/${NOW_EPOCH}-nightly-skip-${DATE}.md" <<BODY
---
KIND: dead-letter
AUTHOR: host@mesh
REASON: offline-at-kickoff
DATE: ${DATE}
---
${agent}@mesh was offline (heartbeat > ${OFFLINE_THRESHOLD}s old) at ${DATE}T03:15Z
kickoff. Skipped from nightly-reflection task dispatch. No retry today.
BODY
}

# 2. Subscribe every registered agent (except host + offline) — idempotent
for reg in "${MESH_ROOT}/mesh/REGISTRY/"*.md; do
    [[ -f "$reg" ]] || continue
    agent="$(basename "$reg" .md)"
    case "$agent" in
        host|REGISTRY|"") continue ;;
        *-CAPABILITIES) continue ;;  # capabilities sidecars are not agents
    esac
    if is_offline "$agent"; then
        log "SKIP offline ${agent}"
        dead_letter_offline "$agent"
        continue
    fi
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
   | timeout 30 "$MESH_EVENT" publish "$TOPIC" --ttl 172800 >>"$LOG" 2>&1; then
    log "ERROR kickoff publish failed"
    exit 1
fi
log "kickoff event published"

# 4. Per-agent KIND:task with REPLY_TO_TOPIC + DEADLINE (carries the contract)
#    These land in the agent's inbox and wake their mesh-watch.
#    Offline agents are already dead-lettered above — skip here too.
for reg in "${MESH_ROOT}/mesh/REGISTRY/"*.md; do
    [[ -f "$reg" ]] || continue
    agent="$(basename "$reg" .md)"
    case "$agent" in
        host|REGISTRY|"") continue ;;
        *-CAPABILITIES) continue ;;  # capabilities sidecars are not agents
    esac
    is_offline "$agent" && continue

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
