#!/usr/bin/env bash
# agent-add.sh — Provision a new agent slot in the Filament mesh.
#
# Creates the host-side directory tree for <agent-name>, sets permissions,
# writes a placeholder REGISTRY/<name>.md row, and prints a docker-compose
# bind-mount fragment.
#
# Does NOT edit compose files. Does NOT restart containers. Host-side prep only.
# Idempotent — safe to re-run.
#
# USAGE:
#   sudo bash scripts/agent-add.sh <agent-name> <owner>
#
# Example:
#   sudo bash scripts/agent-add.sh my-agent my-user
#
# CONFIGURATION:
#   MESH_ROOT        — mesh root (default: /opt/filament-mesh)
#   AGENT_MESH_UID   — container UID owning sent/desk/snapshots (default: 1000)
#   AGENT_MESH_GID   — container GID (default: 1000)

set -eu

MESH_ROOT="${MESH_ROOT:-/opt/filament-mesh}"
AGENTS_DIR="${MESH_ROOT}/agents"
REGISTRY_DIR="${MESH_ROOT}/mesh/REGISTRY"
CC_DIR="${MESH_ROOT}/mesh/cc"

TS="$(date +%Y%m%d-%H%M%S)"

step() { echo; echo "=== $1"; }
info() { echo "    -> $*"; }
die()  { echo "    XX $*" >&2; exit 1; }

AGENT_NAME="${1:-}"
OWNER="${2:-}"

if [[ -z "$AGENT_NAME" || -z "$OWNER" ]]; then
    echo "usage: sudo bash scripts/agent-add.sh <agent-name> <owner>"
    echo "example: sudo bash scripts/agent-add.sh my-agent myuser"
    exit 1
fi

[[ "$AGENT_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "agent-name must be kebab-case"
[[ "$OWNER" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "owner must be kebab-case"
[[ $EUID -eq 0 ]] || die "run as root: sudo bash scripts/agent-add.sh ..."
[[ -d "$MESH_ROOT" ]] || die "mesh root ${MESH_ROOT} not found — run mesh-init.sh first"

tenant_uid="${AGENT_MESH_UID:-1000}"
tenant_gid="${AGENT_MESH_GID:-1000}"
info "UID=${tenant_uid} GID=${tenant_gid} (override via AGENT_MESH_UID/AGENT_MESH_GID)"

# ── 1. Create agent directory tree ───────────────────────────────────────────
step "1. Create agent directory tree"
AGENT_HOME="${AGENTS_DIR}/${AGENT_NAME}"

mkdir -p "${AGENT_HOME}/inbox"
chmod 1733 "${AGENT_HOME}/inbox"

mkdir -p "${AGENT_HOME}/sent" "${AGENT_HOME}/snapshots"
chmod 755 "${AGENT_HOME}/sent" "${AGENT_HOME}/snapshots"

mkdir -p "${AGENT_HOME}/desk"
chmod 700 "${AGENT_HOME}/desk"

chown -R "${tenant_uid}:${tenant_gid}" \
    "${AGENT_HOME}/sent" \
    "${AGENT_HOME}/snapshots" \
    "${AGENT_HOME}/desk"
chown root:root "${AGENT_HOME}" "${AGENT_HOME}/inbox"

if [[ ! -f "${AGENT_HOME}/sent/RECENT.md" ]]; then
    printf '# RECENT.md — auto-tail of recent outgoing\n# Agent: %s@mesh\n# Provisioned: %s\n\n(empty — first boot pending)\n' \
        "$AGENT_NAME" "$TS" > "${AGENT_HOME}/sent/RECENT.md"
    chown "${tenant_uid}:${tenant_gid}" "${AGENT_HOME}/sent/RECENT.md"
fi

info "agent tree ready at ${AGENT_HOME}"

# ── 2. Seed cc/<self>/ ────────────────────────────────────────────────────────
step "2. Seed mesh/cc/${AGENT_NAME}/"
mkdir -p "${CC_DIR}/${AGENT_NAME}"
chmod 1777 "${CC_DIR}/${AGENT_NAME}"

# ── 3. Placeholder REGISTRY row ───────────────────────────────────────────────
step "3. Write REGISTRY/${AGENT_NAME}.md"
REGISTRY_FILE="${REGISTRY_DIR}/${AGENT_NAME}.md"
[[ -f "$REGISTRY_FILE" ]] && cp -a "$REGISTRY_FILE" "${REGISTRY_FILE}.bak-${TS}"

cat > "$REGISTRY_FILE" <<EOF
---
name: ${AGENT_NAME}
uri: ${AGENT_NAME}@mesh
owner: ${OWNER}
capabilities: []
host_notes: "placeholder — agent overwrites on first boot"
first-seen: $(date -u +%Y-%m-%d)
---

# ${AGENT_NAME}@mesh

Placeholder row. Agent has been provisioned but not yet booted.
On first SessionStart the agent overwrites this file with its capabilities.

Provisioned: ${TS}
EOF

# ── 4. Print compose fragment ─────────────────────────────────────────────────
step "4. docker-compose fragment (paste into your service definition)"
cat <<EOF

-------------------------- BEGIN COMPOSE FRAGMENT --------------------------
services:
  <your-container>:
    environment:
      AGENT_URI: ${AGENT_NAME}@mesh
      MESH_ROOT: ${MESH_ROOT}
    volumes:
      # Read-only view of the shared mesh directory
      - ${MESH_ROOT}/mesh:/mesh:ro
      # Read-write overlay for cc/ only
      - ${MESH_ROOT}/mesh/cc:/mesh/cc:rw
      # Own agent directory
      - ${MESH_ROOT}/agents/${AGENT_NAME}:/agent-desk:rw
      # OPTIONAL: cross-peer inbox mounts (uncomment per peer you need to write to)
      # - ${MESH_ROOT}/agents/host/inbox:/peer-inbox/host:rw
      # - ${MESH_ROOT}/agents/<other-agent>/inbox:/peer-inbox/<other-agent>:rw
--------------------------- END COMPOSE FRAGMENT ---------------------------

EOF

echo "Next steps:"
echo "  1. Paste the compose fragment into your container's docker-compose.yml"
echo "  2. docker compose up -d to pick up the new mounts"
echo "  3. Inside container: AGENT_URI=${AGENT_NAME}@mesh mesh-on"
