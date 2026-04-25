#!/usr/bin/env bash
# hackathon-watcher.sh — autonomous hackathon oversight loop.
#
# Every 15 min:
#   1. Read each agent's submissions/<agent>/ANGLE.md and STATUS.md
#   2. Update BLACKBOARD/ovui-lite/LATEST.md status board
#   3. Pull each agent's repo (if claimed) and check commit recency
#   4. If no progress >2h during build phase → ping host inbox
#   5. If two agents claimed same angle_id → flag conflict, drop ping
#   6. If a phase deadline passes → advance phase and announce
#   7. After Phase 5 deadline → run hackathon-aggregate.sh
#
# Idempotent. Pure-readonly except for the LATEST.md regen + STATE_CHECK stamp.

set -uo pipefail

if [[ -f /home/mike/MIKE-AI/scripts/agent-mesh/filament-env.sh ]]; then
    # shellcheck disable=SC1091
    . /home/mike/MIKE-AI/scripts/agent-mesh/filament-env.sh
fi
MESH_ROOT="${MESH_ROOT:-/mnt/agent-mesh}"
HACK_DIR="${MESH_ROOT}/mesh/BLACKBOARD/ovui-lite"
LOG="${LOG_DIR:-/home/mike/MIKE-AI/logs}/hackathon-watcher.log"
mkdir -p "$(dirname "${LOG}")"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*" >> "${LOG}"; }

NOW_EPOCH=$(date +%s)

# Phase deadlines (epoch)
P1_DEADLINE=$(date -u -d '2026-04-25T18:00:00Z' +%s)
P2_DEADLINE=$(date -u -d '2026-04-27T18:00:00Z' +%s)
P3_DEADLINE=$(date -u -d '2026-04-27T20:00:00Z' +%s)
P4_DEADLINE=$(date -u -d '2026-04-28T08:00:00Z' +%s)
P5_DEADLINE=$(date -u -d '2026-04-28T16:00:00Z' +%s)

# Determine current phase
if   (( NOW_EPOCH < P1_DEADLINE )); then PHASE="1-angle-claim"
elif (( NOW_EPOCH < P2_DEADLINE )); then PHASE="2-build"
elif (( NOW_EPOCH < P3_DEADLINE )); then PHASE="3-benchmark"
elif (( NOW_EPOCH < P4_DEADLINE )); then PHASE="4-cross-review"
elif (( NOW_EPOCH < P5_DEADLINE )); then PHASE="5-vote"
else PHASE="6-mike-review"
fi

log "watcher run — phase=${PHASE}"

declare -A AGENT_PHASE AGENT_ANGLE AGENT_REPO AGENT_LAST_UPDATE
AGENTS=(bun-desktop josh-desktop danielle-desktop src-desktop residential-laptop)

for agent in "${AGENTS[@]}"; do
    sub_dir="${HACK_DIR}/submissions/${agent}"
    angle_file="${sub_dir}/ANGLE.md"
    status_file="${sub_dir}/STATUS.md"
    bench_file="${sub_dir}/BENCH.md"

    if [[ -r "$angle_file" ]]; then
        angle_id=$(awk -F': *' '/^angle_id:/{print $2; exit}' "$angle_file" 2>/dev/null | tr -d '"')
        angle_name=$(awk -F': *' '/^angle_name:/{print $2; exit}' "$angle_file" 2>/dev/null | tr -d '"')
        repo_url=$(awk -F': *' '/^repo_url:/{print $2; exit}' "$angle_file" 2>/dev/null | tr -d '"')
        AGENT_ANGLE[$agent]="${angle_id:-?} (${angle_name:-?})"
        AGENT_REPO[$agent]="${repo_url:-?}"
    else
        AGENT_ANGLE[$agent]="(not claimed)"
        AGENT_REPO[$agent]="-"
    fi

    # Last update mtime — most recent of ANGLE/STATUS/BENCH
    last_mt=0
    for f in "$angle_file" "$status_file" "$bench_file"; do
        if [[ -r "$f" ]]; then
            mt=$(stat -c '%Y' "$f")
            (( mt > last_mt )) && last_mt=$mt
        fi
    done
    AGENT_LAST_UPDATE[$agent]=$last_mt

    # Determine per-agent phase status
    case "$PHASE" in
        1-angle-claim)
            if [[ -r "$angle_file" ]]; then
                AGENT_PHASE[$agent]="claimed"
            else
                AGENT_PHASE[$agent]="awaiting-claim"
            fi
            ;;
        2-build)
            if [[ -r "$angle_file" ]]; then
                AGENT_PHASE[$agent]="building"
                # stalled? no update in last 2h
                if (( last_mt > 0 && (NOW_EPOCH - last_mt) > 7200 )); then
                    AGENT_PHASE[$agent]="STALLED"
                fi
            else
                AGENT_PHASE[$agent]="MISSED-CLAIM"
            fi
            ;;
        3-benchmark)
            if [[ -r "$bench_file" ]]; then
                AGENT_PHASE[$agent]="benchmarked"
            elif [[ -r "$angle_file" ]]; then
                AGENT_PHASE[$agent]="awaiting-bench"
            else
                AGENT_PHASE[$agent]="MISSED-BUILD"
            fi
            ;;
        4-cross-review)
            n_reviews_written=$(ls "${HACK_DIR}/submissions/"*"/reviews/${agent}.md" 2>/dev/null | wc -l)
            AGENT_PHASE[$agent]="reviews-written-${n_reviews_written}/4"
            ;;
        5-vote)
            n_votes=$(ls "${MESH_ROOT}/mesh/BLACKBOARD/votes/"*"/${agent}.md" 2>/dev/null | wc -l)
            AGENT_PHASE[$agent]="votes-cast-${n_votes}/4"
            ;;
        6-mike-review)
            AGENT_PHASE[$agent]="hackathon-complete"
            ;;
    esac
done

# Detect angle conflicts
declare -A ANGLE_COUNT
for agent in "${AGENTS[@]}"; do
    angle="${AGENT_ANGLE[$agent]}"
    [[ "$angle" == "(not claimed)" ]] && continue
    angle_id="${angle%% *}"
    ANGLE_COUNT[$angle_id]=$(( ${ANGLE_COUNT[$angle_id]:-0} + 1 ))
done

CONFLICTS=()
for id in "${!ANGLE_COUNT[@]}"; do
    if (( ${ANGLE_COUNT[$id]} > 1 )); then
        CONFLICTS+=("angle_id=${id} claimed by ${ANGLE_COUNT[$id]} agents")
    fi
done

# Regenerate LATEST.md
{
    echo "---"
    echo "pointer: BRIEF.md"
    echo "phase: ${PHASE}"
    echo "regenerated: $(ts)"
    echo "host: host@mesh"
    if (( ${#CONFLICTS[@]} > 0 )); then
        echo "angle_conflicts:"
        for c in "${CONFLICTS[@]}"; do echo "  - ${c}"; done
    fi
    echo "---"
    echo
    echo "# OVUI-Lite Hackathon — LATEST"
    echo
    echo "**Phase:** ${PHASE}"
    echo "**Brief:** \`BLACKBOARD/ovui-lite/BRIEF.md\`"
    echo "**Submissions:** \`BLACKBOARD/ovui-lite/submissions/<agent>/\`"
    echo
    echo "## Status board"
    echo
    echo "| Agent | Phase | Angle | Repo | Last update |"
    echo "|---|---|---|---|---|"
    for agent in "${AGENTS[@]}"; do
        last=${AGENT_LAST_UPDATE[$agent]}
        if (( last > 0 )); then
            age=$(( (NOW_EPOCH - last) / 60 ))
            last_str="${age}m ago"
        else
            last_str="—"
        fi
        echo "| ${agent} | ${AGENT_PHASE[$agent]} | ${AGENT_ANGLE[$agent]} | ${AGENT_REPO[$agent]} | ${last_str} |"
    done
    echo
    if (( ${#CONFLICTS[@]} > 0 )); then
        echo "## ⚠️ Conflicts"
        echo
        for c in "${CONFLICTS[@]}"; do echo "- ${c}"; done
        echo
        echo "Resolution: agents involved should re-read BRIEF.md §Phase 1; mkdir-claim-loser must pick another angle and update their ANGLE.md."
        echo
    fi
    echo "(Updated automatically by \`hackathon-watcher.sh\` every 15 min.)"
} > "${HACK_DIR}/LATEST.md"

log "  status: ${PHASE}; agents claimed: $(grep -c claimed <<< "${AGENT_PHASE[*]}"); conflicts: ${#CONFLICTS[@]}"

# Stamp STATE_CHECK
sc_file="${MESH_ROOT}/mesh/STATE_CHECK/$(date -u +%Y-%m-%dT%H%M%SZ)-host-hackathon-watcher.md"
{
    echo "## host@mesh @ $(ts)"
    echo "- hackathon-phase: ${PHASE}"
    for agent in "${AGENTS[@]}"; do
        echo "- hackathon-${agent}-phase: ${AGENT_PHASE[$agent]}"
    done
    if (( ${#CONFLICTS[@]} > 0 )); then
        echo "- hackathon-conflicts:"
        for c in "${CONFLICTS[@]}"; do echo "  - ${c}"; done
    fi
} > "${sc_file}"

# Ping host inbox if any agent stalled
STALLED_AGENTS=()
for agent in "${AGENTS[@]}"; do
    if [[ "${AGENT_PHASE[$agent]}" == "STALLED" ]]; then
        STALLED_AGENTS+=("$agent")
    fi
done

if (( ${#STALLED_AGENTS[@]} > 0 )); then
    # Don't double-ping if already pinged this hour
    pingfile="${HACK_DIR}/.last-stall-ping"
    last_ping=$(cat "$pingfile" 2>/dev/null || echo 0)
    if (( NOW_EPOCH - last_ping > 3600 )); then
        echo "${NOW_EPOCH}" > "$pingfile"
        host_inbox="${MESH_ROOT}/agents/host/inbox"
        date_pfx=$(date -u +%Y-%m-%d)
        for n in $(seq -w 001 999); do
            target="${host_inbox}/${date_pfx}-${n}-host-hackathon-stalled-agents.md"
            [[ -e "$target" ]] || break
        done
        {
            echo "---"
            echo "KIND: announcement"
            echo "AUTHOR: host@mesh"
            echo "READERS: [host@mesh]"
            echo "REPLIES-TO: null"
            echo "SIZE: short"
            echo "END-OF-TURN: host@mesh — check stalled agents"
            echo "---"
            echo
            echo "Hackathon watcher detected stalled agents (>2h no update during build phase):"
            for a in "${STALLED_AGENTS[@]}"; do
                echo "- ${a}: ${AGENT_REPO[$a]}"
            done
            echo
            echo "Action: pull their repo and check commit recency. If genuinely stuck, drop a question or unblock. If session crashed, ping them."
        } > "$target"
        log "  STALLED ping written: ${target}"
    fi
fi

# At Phase 6 entry — auto-run aggregator
if [[ "$PHASE" == "6-mike-review" && ! -r "${HACK_DIR}/RESULTS.md" ]]; then
    if [[ -x /home/mike/MIKE-AI/scripts/agent-mesh/hackathon-aggregate.sh ]]; then
        log "  Phase 6 entered — running hackathon-aggregate.sh"
        bash /home/mike/MIKE-AI/scripts/agent-mesh/hackathon-aggregate.sh >> "${LOG}" 2>&1
    fi
fi

exit 0
