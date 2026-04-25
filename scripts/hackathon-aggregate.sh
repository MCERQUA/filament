#!/usr/bin/env bash
# hackathon-aggregate.sh — Phase 6: build the comparison matrix for Mike.
#
# Reads every submission's ANGLE.md / BENCH.md / votes / reviews and
# produces a single RESULTS.md + a canvas-page comparison.
#
# Run automatically by hackathon-watcher.sh when Phase 6 starts; can also
# be run manually any time after Phase 5 closes.

set -uo pipefail

if [[ -f /home/mike/MIKE-AI/scripts/agent-mesh/filament-env.sh ]]; then
    # shellcheck disable=SC1091
    . /home/mike/MIKE-AI/scripts/agent-mesh/filament-env.sh
fi
MESH_ROOT="${MESH_ROOT:-/mnt/agent-mesh}"
HACK_DIR="${MESH_ROOT}/mesh/BLACKBOARD/ovui-lite"
RESULTS="${HACK_DIR}/RESULTS.md"
LOG="${LOG_DIR:-/home/mike/MIKE-AI/logs}/hackathon-aggregate.log"
mkdir -p "$(dirname "${LOG}")"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*" >> "${LOG}"; }

AGENTS=(bun-desktop josh-desktop danielle-desktop src-desktop residential-laptop)

log "aggregate run start"

{
    echo "---"
    echo "title: OVUI-Lite Hackathon — Results"
    echo "generated: $(ts)"
    echo "host: host@mesh"
    echo "---"
    echo
    echo "# OVUI-Lite Hackathon — Results"
    echo
    echo "Generated $(ts) by hackathon-aggregate.sh."
    echo "See \`BRIEF.md\` for the original spec."
    echo
    echo "## Submissions matrix"
    echo
    echo "| Agent | Angle | Repo | Cold-start | Idle RSS | Active RSS | Disk | Votes Y/N/abs/blk | Verdict |"
    echo "|---|---|---|---:|---:|---:|---:|---:|---|"

    for agent in "${AGENTS[@]}"; do
        sub_dir="${HACK_DIR}/submissions/${agent}"
        angle_file="${sub_dir}/ANGLE.md"
        bench_file="${sub_dir}/BENCH.md"

        if [[ ! -r "$angle_file" ]]; then
            echo "| ${agent} | NO SUBMISSION | — | — | — | — | — | — | DID NOT SUBMIT |"
            continue
        fi

        angle_name=$(awk -F': *' '/^angle_name:/{print $2; exit}' "$angle_file" 2>/dev/null | tr -d '"')
        repo_url=$(awk -F': *' '/^repo_url:/{print $2; exit}' "$angle_file" 2>/dev/null | tr -d '"')

        cold="—"; idle_rss="—"; active_rss="—"; disk="—"
        if [[ -r "$bench_file" ]]; then
            cold=$(grep '| Cold-start ' "$bench_file" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
            idle_rss=$(grep '| Idle RSS ' "$bench_file" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
            active_rss=$(grep '| Active RSS ' "$bench_file" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
            disk=$(grep '| Disk install ' "$bench_file" | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}')
        fi

        # Vote tally — search BLACKBOARD/votes/ for this submission's stem
        vote_stem="ANGLE-${agent}"
        votes_dir="${MESH_ROOT}/mesh/BLACKBOARD/votes/${vote_stem}"
        y=0; n=0; abs=0; blk=0
        if [[ -d "$votes_dir" ]]; then
            for vf in "$votes_dir"/*.md; do
                [[ -r "$vf" ]] || continue
                v=$(awk -F': *' '/^vote:/{print $2; exit}' "$vf" 2>/dev/null | tr -d '" ')
                case "$v" in
                    yes) y=$((y+1)) ;;
                    no) n=$((n+1)) ;;
                    abstain) abs=$((abs+1)) ;;
                    block) blk=$((blk+1)) ;;
                esac
            done
        fi

        verdict="—"
        if (( blk > 0 )); then verdict="BLOCKED"
        elif (( n >= 3 )); then verdict="CONTESTED"
        elif (( y > n )); then verdict="RATIFIED"
        elif (( n > y )); then verdict="REJECTED"
        fi

        echo "| ${agent} | ${angle_name:-?} | ${repo_url:-?} | ${cold} | ${idle_rss} | ${active_rss} | ${disk} | ${y}/${n}/${abs}/${blk} | ${verdict} |"
    done

    echo
    echo "## Per-agent details"
    echo
    for agent in "${AGENTS[@]}"; do
        sub_dir="${HACK_DIR}/submissions/${agent}"
        if [[ ! -r "${sub_dir}/ANGLE.md" ]]; then continue; fi
        echo "### ${agent}"
        echo
        echo "**ANGLE.md:**"
        echo
        echo '```'
        head -40 "${sub_dir}/ANGLE.md"
        echo '```'
        if [[ -r "${sub_dir}/BENCH.md" ]]; then
            echo
            echo "**BENCH.md:**"
            echo
            echo '```'
            cat "${sub_dir}/BENCH.md"
            echo '```'
        fi
        if [[ -d "${sub_dir}/reviews" ]]; then
            echo
            echo "**Reviews received:**"
            echo
            for rf in "${sub_dir}/reviews"/*.md; do
                [[ -r "$rf" ]] || continue
                echo "- $(basename "$rf" .md):"
                echo
                echo '```'
                head -30 "$rf"
                echo '```'
            done
        fi
        echo
    done

    echo "---"
    echo
    echo "## Mike's call"
    echo
    echo "Mike picks one or more submissions for production. Others remain archived."
    echo "Production winner: _(Mike fills in)_"
} > "${RESULTS}"

log "wrote ${RESULTS}"

# Also drop a notification to host inbox so Mike sees a clear ping
host_inbox="${MESH_ROOT}/agents/host/inbox"
date_pfx=$(date -u +%Y-%m-%d)
for n in $(seq -w 001 999); do
    target="${host_inbox}/${date_pfx}-${n}-host-hackathon-results-ready.md"
    [[ -e "$target" ]] || break
done
{
    echo "---"
    echo "KIND: announcement"
    echo "AUTHOR: host@mesh"
    echo "READERS: [host@mesh, mike-direct]"
    echo "REPLIES-TO: null"
    echo "SIZE: medium"
    echo "END-OF-TURN: mike-direct — pick winner(s)"
    echo "---"
    echo
    echo "OVUI-Lite Hackathon RESULTS aggregated — Mike review pending."
    echo
    echo "  /mesh/BLACKBOARD/ovui-lite/RESULTS.md"
    echo
    head -25 "${RESULTS}"
} > "$target"

log "host inbox notification: $target"
echo "Done. ${RESULTS}"
