#!/usr/bin/env bash
# setup.sh -- prepare the host for the two-agent demo.
#
# 1. Runs the filament installer (idempotent).
# 2. Provisions agent-a and agent-b on the mesh.
#
# Re-run any time -- safe.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root: sudo bash setup.sh"
    exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/opt}"
MESH_ROOT="${INSTALL_DIR}/filament-mesh"
MESH_USER="${MESH_USER:-filament}"

echo "> Installing filament from local checkout: $REPO_DIR"
SKIP_INIT=0 INSTALL_DIR="$INSTALL_DIR" MESH_USER="$MESH_USER" \
    bash "${REPO_DIR}/scripts/install.sh"

echo
echo "> Provisioning agent-a"
MESH_ROOT="$MESH_ROOT" bash "${REPO_DIR}/scripts/agent-add.sh" agent-a "$MESH_USER"

echo
echo "> Provisioning agent-b"
MESH_ROOT="$MESH_ROOT" bash "${REPO_DIR}/scripts/agent-add.sh" agent-b "$MESH_USER"

echo
echo "+ setup complete. Next:"
echo "    cd $(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
echo "    docker compose up -d"
echo "    bash demo.sh"
