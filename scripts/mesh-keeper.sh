#!/usr/bin/env bash
# mesh-keeper.sh — generic active-oversight enforcer.
#
# The watcher reports state. The keeper makes things happen.
#
# For every workstream registered under scripts/agent-mesh/keepers/<name>.sh,
# the keeper runs the workstream's check_and_redrop() function. If progress
# is stale, the workstream's policy decides whether to re-drop a task,
# escalate to host, or kick a synthesis script.
#
# Cadence: every 15 min via cron. Each workstream policy decides its own
# stall threshold and re-drop interval.
#
# Each workstream policy script must export two functions:
#   workstream_name()      — short identifier (e.g. "hackathon")
#   workstream_run()       — does the work; returns 0 always
# and may use these helpers from this file:
#   redrop_task <agent> <subject> <body-file>
#   escalate <agent> <reason>
#   touch_redrop <agent>            — record a re-drop happened
#   redrop_count <agent>            — return consecutive re-drop count
#   reset_redrop <agent>            — agent moved, reset counter

set -uo pipefail

if [[ -f /home/mike/MIKE-AI/scripts/agent-mesh/filament-env.sh ]]; then
    # shellcheck disable=SC1091
    . /home/mike/MIKE-AI/scripts/agent-mesh/filament-env.sh
fi
MESH_ROOT="${MESH_ROOT:-/mnt/agent-mesh}"
KEEPER_DIR="/home/mike/MIKE-AI/scripts/agent-mesh/keepers"
STATE_DIR="${MESH_ROOT}/mesh/keepers/state"
LOG="${LOG_DIR:-/home/mike/MIKE-AI/logs}/mesh-keeper.log"
mkdir -p "${STATE_DIR}" "$(dirname "${LOG}")"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*" >> "${LOG}"; }

NOW=$(date +%s)

# ---------------------------------------------------------------------------
# Helpers exported to workstream scripts
# ---------------------------------------------------------------------------

# Drop a task to an agent's inbox (the active-prompting primitive).
# Args: agent, subject, body-file
redrop_task() {
    local agent="$1"; local subject="$2"; local body_file="$3"
    local inbox="${MESH_ROOT}/agents/${agent}/inbox"
    [[ -d "$inbox" ]] || { log "  redrop_task: ${agent} inbox missing"; return 1; }
    local date_pfx=$(date -u +%Y-%m-%d)
    local target
    for n in $(seq -w 001 999); do
        target="${inbox}/${date_pfx}-${n}-host-keeper-${subject}.md"
        [[ -e "$target" ]] || break
    done
    {
        echo "---"
        echo "KIND: task"
        echo "AUTHOR: host@mesh"
        echo "READERS: [${agent}@mesh]"
        echo "REPLIES-TO: null"
        echo "SIZE: medium"
        echo "END-OF-TURN: ${agent}@mesh — resume work"
        echo "REDROP_BY: host@mesh keeper @ $(ts)"
        echo "---"
        echo
        cat "$body_file"
    } > "$target"
    log "  REDROP: ${agent} ← ${subject} (${target})"
    touch_redrop "$agent" "$subject"
}

# Escalate to host inbox — for cases where N re-drops produced no response,
# implying genuine block.
escalate() {
    local agent="$1"; local reason="$2"
    local inbox="${MESH_ROOT}/agents/host/inbox"
    local date_pfx=$(date -u +%Y-%m-%d)
    local target
    for n in $(seq -w 001 999); do
        target="${inbox}/${date_pfx}-${n}-host-keeper-escalation-${agent}.md"
        [[ -e "$target" ]] || break
    done
    {
        echo "---"
        echo "KIND: announcement"
        echo "AUTHOR: host@mesh"
        echo "READERS: [host@mesh]"
        echo "REPLIES-TO: null"
        echo "SIZE: short"
        echo "END-OF-TURN: host@mesh — investigate stalled agent"
        echo "---"
        echo
        echo "Keeper escalation — ${agent} unresponsive after multiple re-drops."
        echo "Reason: ${reason}"
        echo "Action: investigate. Possible: agent session crashed, blocker undocumented, container down."
    } > "$target"
    log "  ESCALATE: ${agent} (${reason})"
}

# Per-(agent,subject) re-drop tracking
touch_redrop() {
    local agent="$1"; local subject="$2"
    local f="${STATE_DIR}/${agent}.${subject}.redrops"
    local count=$(cat "$f" 2>/dev/null || echo 0)
    echo $((count + 1)) > "$f"
    echo "${NOW}" > "${STATE_DIR}/${agent}.${subject}.last-redrop"
}

redrop_count() {
    local agent="$1"; local subject="$2"
    cat "${STATE_DIR}/${agent}.${subject}.redrops" 2>/dev/null || echo 0
}

last_redrop() {
    local agent="$1"; local subject="$2"
    cat "${STATE_DIR}/${agent}.${subject}.last-redrop" 2>/dev/null || echo 0
}

reset_redrop() {
    local agent="$1"; local subject="$2"
    rm -f "${STATE_DIR}/${agent}.${subject}.redrops" "${STATE_DIR}/${agent}.${subject}.last-redrop"
}

export -f redrop_task escalate touch_redrop redrop_count last_redrop reset_redrop log ts
export MESH_ROOT STATE_DIR NOW LOG

# ---------------------------------------------------------------------------
# Run all registered keepers
# ---------------------------------------------------------------------------
log "keeper run start"

if [[ ! -d "$KEEPER_DIR" ]]; then
    log "  no keeper dir — exiting"
    exit 0
fi

shopt -s nullglob
for ks in "${KEEPER_DIR}"/*.sh; do
    name=$(basename "${ks}" .sh)
    log "  → running keeper: ${name}"
    bash "${ks}" 2>&1 | sed "s/^/    /" >> "${LOG}" || log "    keeper ${name} EXITED ABNORMALLY"
done
shopt -u nullglob

# Stamp STATE_CHECK
sc_dir="${MESH_ROOT}/mesh/STATE_CHECK"
mkdir -p "$sc_dir"
sc_file="${sc_dir}/$(date -u +%Y-%m-%dT%H%M%SZ)-host-mesh-keeper.md"
{
    echo "## host@mesh @ $(ts)"
    echo "- mesh-keeper-run-at: $(ts)"
    echo "- mesh-keeper-active-keepers: $(ls "${KEEPER_DIR}"/*.sh 2>/dev/null | wc -l)"
} > "$sc_file"

log "keeper run complete"
