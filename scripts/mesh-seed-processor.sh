#!/usr/bin/env bash
# mesh-seed-processor.sh — Auto-provision new agents from SEED/*.json files.
#
# Runs every 5 min via cron. For each unprocessed seed file, calls agent-add.sh
# to provision the agent dirs. After processing, renames seed to *.provisioned-<ts>.
#
# Seed file schema (mesh/SEED/<agent-name>.json):
#   agent_name    string  — kebab-case
#   owner         string  — owning user/tenant
#   uid           int     — container UID for file ownership (default 1000)
#   gid           int     — container GID (default 1000)
#
# Requires: jq
# Install: */5 * * * * MESH_ROOT=/opt/filament-mesh bash /path/to/scripts/mesh-seed-processor.sh

set -euo pipefail

MESH_ROOT="${MESH_ROOT:-/opt/filament-mesh}"
SEED_DIR="${MESH_ROOT}/mesh/SEED"
AGENTS_DIR="${MESH_ROOT}/agents"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -d "$SEED_DIR" ]] || exit 0

shopt -s nullglob
seeds=("${SEED_DIR}"/*.json)
shopt -u nullglob
[[ ${#seeds[@]} -eq 0 ]] && exit 0

for seed in "${seeds[@]}"; do
    agent_name=$(jq -r '.agent_name // empty' "$seed" 2>/dev/null)
    if [[ -z "$agent_name" ]]; then
        echo "mesh-seed: SKIP $seed — missing agent_name"
        continue
    fi

    ts=$(date -u +%Y%m%d-%H%M%S)
    if [[ -d "${AGENTS_DIR}/${agent_name}" ]]; then
        mv "$seed" "${seed%.json}.provisioned-${ts}-already-existed"
        echo "mesh-seed: $agent_name already exists — marked processed"
        continue
    fi

    owner=$(jq -r '.owner // ""' "$seed")
    uid=$(jq -r '.uid // 1000' "$seed")
    gid=$(jq -r '.gid // 1000' "$seed")

    echo "mesh-seed: provisioning $agent_name (owner: $owner)"

    if MESH_ROOT="$MESH_ROOT" AGENT_MESH_UID="$uid" AGENT_MESH_GID="$gid" \
        bash "${SCRIPT_DIR}/agent-add.sh" "$agent_name" "$owner" 2>&1; then
        mv "$seed" "${seed%.json}.provisioned-${ts}"
        echo "mesh-seed: $agent_name provisioned successfully"
    else
        echo "mesh-seed: ERROR provisioning $agent_name — seed left for retry"
    fi
done
