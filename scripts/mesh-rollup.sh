#!/usr/bin/env bash
# mesh-rollup.sh — 5-min cron. Regenerates REGISTRY.md, STATE_CHECK.md,
# and residential pool schedule summary.
#
# Install via mesh-init.sh, or manually:
#   */5 * * * * MESH_ROOT=/opt/filament-mesh bash /path/to/scripts/mesh-rollup.sh

set -eu

MESH_ROOT="${MESH_ROOT:-/opt/filament-mesh}"
MESH_DIR="${MESH_ROOT}/mesh"
REGISTRY_DIR="${MESH_DIR}/REGISTRY"
REGISTRY_MD="${MESH_DIR}/REGISTRY.md"
STATE_DIR="${MESH_DIR}/STATE_CHECK"
STATE_MD="${MESH_DIR}/STATE_CHECK.md"

[[ -d "$MESH_DIR" ]] || exit 0

# ── REGISTRY.md ───────────────────────────────────────────────────────────────
mkdir -p "$REGISTRY_DIR"
tmp="${REGISTRY_MD}.tmp.$$"
{
    echo "# REGISTRY.md — rollup of mesh/REGISTRY/*.md"
    echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "## Peers"
    echo
    for f in "$REGISTRY_DIR"/*.md; do
        [[ -f "$f" ]] || continue
        echo "- $(basename "$f" .md)@mesh"
    done
    echo
    echo "---"
    echo
    for f in "$REGISTRY_DIR"/*.md; do
        [[ -f "$f" ]] || continue
        echo "### $(basename "$f" .md)@mesh"
        echo
        cat "$f"
        echo
    done
} > "$tmp"
mv -f "$tmp" "$REGISTRY_MD"

# ── STATE_CHECK.md (latest 20) ────────────────────────────────────────────────
mkdir -p "$STATE_DIR"
tmp="${STATE_MD}.tmp.$$"
{
    echo "# STATE_CHECK.md — latest 20 entries from mesh/STATE_CHECK/"
    echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    ls -1 "$STATE_DIR" 2>/dev/null | sort | tail -20 | tac | while read -r name; do
        f="${STATE_DIR}/${name}"
        [[ -f "$f" ]] || continue
        echo "## ${name}"
        echo
        cat "$f"
        echo
        echo "---"
        echo
    done
} > "$tmp"
mv -f "$tmp" "$STATE_MD"

# ── Residential pool schedule summary ────────────────────────────────────────
BLACKBOARD_DIR="${MESH_DIR}/BLACKBOARD"
POOL_SUMMARY="${BLACKBOARD_DIR}/residential-pool/schedule-summary.md"
mkdir -p "${BLACKBOARD_DIR}/residential-pool"

shopt -s nullglob
residential_schedules=("${BLACKBOARD_DIR}"/residential-*/schedule.md)
shopt -u nullglob

tmp="${POOL_SUMMARY}.tmp.$$"
{
    echo "# residential-pool/schedule-summary.md"
    echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Nodes: ${#residential_schedules[@]}"
    echo
    if [[ ${#residential_schedules[@]} -eq 0 ]]; then
        echo "(no residential nodes have posted a schedule)"
    else
        for sched in "${residential_schedules[@]}"; do
            node_name=$(basename "$(dirname "$sched")")
            echo "## ${node_name}@mesh"
            echo
            in_table=0
            while IFS= read -r line; do
                if [[ "$line" == "| Time"* ]]; then in_table=1; fi
                [[ $in_table -eq 1 ]] && echo "$line"
            done < "$sched"
            echo
        done
    fi
} > "$tmp"
mv -f "$tmp" "$POOL_SUMMARY"
