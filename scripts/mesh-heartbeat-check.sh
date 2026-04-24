#!/usr/bin/env bash
# mesh-heartbeat-check.sh — Liveness check cron for Filament agents.
#
# 1. Reads heartbeat stamps from mesh/HEARTBEAT/<agent>.last
# 2. Writes STATE_CHECK alerts on transitions (online → offline, etc.)
# 3. On residential node recovery, replays dead letters
#
# Agents write their own heartbeat stamps (via mesh-send --kind heartbeat
# or directly to HEARTBEAT/<name>.last). This script is the host-side checker.
#
# Install via mesh-init.sh, or manually:
#   */5 * * * * MESH_ROOT=/opt/filament-mesh bash /path/to/scripts/mesh-heartbeat-check.sh

set -euo pipefail

MESH_ROOT="${MESH_ROOT:-/opt/filament-mesh}"
AGENTS_DIR="${MESH_ROOT}/agents"
MESH_DIR="${MESH_ROOT}/mesh"
HEARTBEAT_DIR="${MESH_DIR}/HEARTBEAT"
STATE_CHECK_DIR="${MESH_DIR}/STATE_CHECK"
DEAD_LETTER_RESIDENTIAL="${MESH_DIR}/DEAD_LETTER/residential-pool"

mkdir -p "$HEARTBEAT_DIR" "$STATE_CHECK_DIR"

now=$(date +%s)
ts_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ts_file=$(date -u +%Y-%m-%dT%H%M%SZ)

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

STATE_FILE="/tmp/filament-heartbeat-state.txt"
touch "$STATE_FILE"

prev_status() {
    grep "^${1}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "unknown"
}
set_status() {
    if grep -q "^${1}=" "$STATE_FILE" 2>/dev/null; then
        sed -i "s|^${1}=.*|${1}=${2}|" "$STATE_FILE"
    else
        echo "${1}=${2}" >> "$STATE_FILE"
    fi
}
write_state_check() {
    local agent="$1" event="$2" detail="$3"
    cat > "${STATE_CHECK_DIR}/${ts_file}-host-hb-${agent}-${event}.md" <<EOF
## host@mesh @ ${ts_iso}
- event: heartbeat-${event}
- agent: ${agent}@mesh
- detail: ${detail}
EOF
}

STALE_THRESHOLD=600     # 10 min no heartbeat → stale
OFFLINE_THRESHOLD=1800  # 30 min → offline

# ── Check all agents with heartbeat files ─────────────────────────────────────
for hb_file in "${HEARTBEAT_DIR}"/*.last; do
    [[ -f "$hb_file" ]] || continue
    agent_name=$(basename "$hb_file" .last)

    mtime=$(stat -c %Y "$hb_file" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    prev=$(prev_status "$agent_name")

    if (( age >= OFFLINE_THRESHOLD )); then
        status="offline"
        if [[ "$prev" != "offline" ]]; then
            log "OFFLINE: ${agent_name}@mesh — heartbeat age ${age}s"
            write_state_check "$agent_name" "offline" "heartbeat age ${age}s"
        fi
    elif (( age >= STALE_THRESHOLD )); then
        status="stale"
        if [[ "$prev" != "stale" && "$prev" != "offline" ]]; then
            log "STALE: ${agent_name}@mesh — heartbeat age ${age}s"
        fi
    else
        status="alive"
        if [[ "$prev" == "offline" || "$prev" == "stale" ]]; then
            log "RECOVERED: ${agent_name}@mesh — heartbeat age ${age}s"
            write_state_check "$agent_name" "recovered" "heartbeat age ${age}s"
        fi
    fi
    set_status "$agent_name" "$status"
done

# ── Check residential pool nodes (extended 5-state heartbeat) ────────────────
RESIDENTIAL_STALE=120
RESIDENTIAL_OFFLINE=600
newly_available=()

for agent_dir in "${AGENTS_DIR}"/residential-*/; do
    [[ -d "$agent_dir" ]] || continue
    agent_name=$(basename "$agent_dir")
    hb="${agent_dir}/status/heartbeat.txt"
    prev=$(prev_status "$agent_name")

    if [[ ! -f "$hb" ]]; then
        [[ "$prev" != "offline" ]] && { log "OFFLINE: ${agent_name}@mesh — no heartbeat file"; write_state_check "$agent_name" "offline" "heartbeat.txt missing"; }
        set_status "$agent_name" "offline"
        echo "${ts_iso} offline (no heartbeat file)" > "${HEARTBEAT_DIR}/${agent_name}.last"
        continue
    fi

    mtime=$(stat -c %Y "$hb" 2>/dev/null || echo 0)
    age=$(( now - mtime ))
    node_status=$(grep "^node_status:" "$hb" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]' || true)
    hb_ts=$(grep "^timestamp:" "$hb" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]' || true)
    [[ -z "$node_status" ]] && node_status=$( (( age < RESIDENTIAL_STALE )) && echo "available" || echo "offline" )

    if (( age >= RESIDENTIAL_OFFLINE )); then effective_status="offline"
    elif (( age >= RESIDENTIAL_STALE )); then effective_status="stale"
    else effective_status="$node_status"
    fi

    if [[ "$effective_status" == "offline" && "$prev" != "offline" ]]; then
        log "OFFLINE: ${agent_name}@mesh — heartbeat age ${age}s"
        write_state_check "$agent_name" "offline" "heartbeat age ${age}s"
    elif [[ "$effective_status" == "available" && ( "$prev" == "offline" || "$prev" == "stale" ) ]]; then
        log "RECOVERED: ${agent_name}@mesh — now available"
        write_state_check "$agent_name" "recovered" "node_status=available, age ${age}s"
        newly_available+=("$agent_name")
    fi

    set_status "$agent_name" "$effective_status"
    echo "${ts_iso} ${effective_status} age=${age}s node_status=${node_status}" > "${HEARTBEAT_DIR}/${agent_name}.last"
done

# ── Replay dead letters on residential recovery ───────────────────────────────
if [[ ${#newly_available[@]} -gt 0 ]] && [[ -d "$DEAD_LETTER_RESIDENTIAL" ]]; then
    log "Residential recovery — scanning dead-letter queue"
    shopt -s nullglob
    dead_tasks=("${DEAD_LETTER_RESIDENTIAL}"/*.md)
    shopt -u nullglob

    if [[ ${#dead_tasks[@]} -gt 0 ]]; then
        best_agent=$(MESH_ROOT="${MESH_ROOT}" bash "$(dirname "$0")/../../bin/mesh-pick-residential" 2>/dev/null || echo "none")
        if [[ "$best_agent" != "none" ]]; then
            agent_short="${best_agent%@mesh}"
            target_inbox="${AGENTS_DIR}/${agent_short}/inbox"
            for dead_file in "${dead_tasks[@]}"; do
                deadline=$(grep "^DEADLINE:" "$dead_file" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]')
                if [[ -n "$deadline" && "$deadline" != "null" ]]; then
                    deadline_epoch=$(date -d "$deadline" +%s 2>/dev/null || echo 0)
                    (( now > deadline_epoch )) && { mv "$dead_file" "${dead_file%.md}.expired.md"; continue; }
                fi
                new_fname="$(date -u +%Y-%m-%d)-001-host-residential-replay-$(basename "$dead_file")"
                cp "$dead_file" "${target_inbox}/${new_fname}"
                mv "$dead_file" "${dead_file%.md}.replayed.md"
                log "REPLAYED: $(basename "$dead_file") → ${agent_short}/inbox"
            done
        fi
    fi
fi

# ── Host's own heartbeat ──────────────────────────────────────────────────────
echo "${ts_iso} alive" > "${HEARTBEAT_DIR}/host.last"
log "Heartbeat check complete"
