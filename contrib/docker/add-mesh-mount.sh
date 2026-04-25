#!/usr/bin/env bash
# add-mesh-mount.sh -- generalized rw bind-mount adder for /mesh/* paths.
#
# Use case: the host creates a new shared directory under MESH_ROOT/mesh/ and
# every agent that needs to write to it must have a corresponding rw bind-mount
# in its docker-compose.yml. This script encodes that "never mkdir without
# bind-mount" rule -- one command updates every agent.
#
# Idempotent. Recreates affected containers to apply the new mount.
#
# USAGE:
#   AGENTS=agent-a,agent-b,agent-c sudo bash add-mesh-mount.sh <mesh-relative-path>
#
# Examples:
#   AGENTS=agent-a,agent-b sudo bash add-mesh-mount.sh UPGRADES
#   AGENTS=agent-a sudo bash add-mesh-mount.sh EVENTS/.processed
#
# Configuration (env):
#   AGENTS               required. Comma-separated agent names.
#   MESH_ROOT            mesh root on host (default: /opt/filament-mesh)
#   COMPOSE_DIR_TPL      where to find compose files (default: /opt/agents/<name>/docker-compose.yml)
#                        $NAME is replaced with the agent name.
#   CONTAINER_TPL        container name template (default: <name>)
#                        $NAME is replaced with the agent name.
#   SHARED_NETWORK       optional shared network to reconnect (default: empty -- skip)
#   DOCKER_CMD           how to invoke docker (default: docker; use "sg docker -c \"docker\"" if not in group)

set -euo pipefail

MESH_PATH="${1:-}"
[[ -z "$MESH_PATH" ]] && { echo "usage: AGENTS=a,b,c $0 <mesh-relative-path>"; exit 1; }

MESH_ROOT="${MESH_ROOT:-/opt/filament-mesh}"
COMPOSE_DIR_TPL="${COMPOSE_DIR_TPL:-/opt/agents/\$NAME/docker-compose.yml}"
CONTAINER_TPL="${CONTAINER_TPL:-\$NAME}"
SHARED_NETWORK="${SHARED_NETWORK:-}"
DOCKER_CMD="${DOCKER_CMD:-docker}"

# Read AGENTS env (comma-separated)
IFS=',' read -ra AGENT_LIST <<< "${AGENTS:-}"
if [[ ${#AGENT_LIST[@]} -eq 0 ]] || [[ -z "${AGENT_LIST[0]}" ]]; then
    echo "ERROR: set AGENTS=name1,name2,... (comma-separated)" >&2
    exit 1
fi

# Normalize: strip leading slash and any /mesh/ prefix
MESH_PATH="${MESH_PATH#/}"
MESH_PATH="${MESH_PATH#mesh/}"

HOST_PATH="${MESH_ROOT}/mesh/${MESH_PATH}"
CONTAINER_PATH="/mesh/${MESH_PATH}"
MOUNT_LINE="      - ${HOST_PATH}:${CONTAINER_PATH}:rw"

# Ensure host dir exists
mkdir -p "$HOST_PATH"
echo "> host dir: $HOST_PATH"

for name in "${AGENT_LIST[@]}"; do
    [[ -z "$name" ]] && continue
    name="$(echo "$name" | xargs)" # trim whitespace

    # Resolve templates
    compose=$(eval "echo \"$COMPOSE_DIR_TPL\"" | sed "s|\$NAME|$name|g")
    compose="${compose//\$NAME/$name}"
    container=$(echo "$CONTAINER_TPL" | sed "s|\$NAME|$name|g")
    container="${container//\$NAME/$name}"

    echo ""
    echo "> $name (compose=$compose  container=$container)"

    if [[ ! -f "$compose" ]]; then
        echo "  WARN: compose file not found, skipping"
        continue
    fi

    if grep -q "${CONTAINER_PATH}:rw\|${CONTAINER_PATH}:ro" "$compose"; then
        echo "  + already mounted"
        continue
    fi

    cp "$compose" "${compose}.bak.$(date +%s)"

    # Anchor: prefer to insert after a read-only base /mesh mount line if present.
    # Otherwise append before the next blank line in the volumes block.
    if grep -q "${MESH_ROOT}/mesh:/mesh:ro" "$compose"; then
        sed -i "\|${MESH_ROOT}/mesh:/mesh:ro|a\\${MOUNT_LINE}" "$compose"
    else
        # Fallback: append at end (operator should verify placement)
        printf '\n# filament: appended by add-mesh-mount.sh\n%s\n' "$MOUNT_LINE" >> "$compose"
        echo "  WARN: no anchor line found, appended at end -- verify placement"
    fi
    echo "  + mount added to $compose"

    # Recreate container
    if $DOCKER_CMD compose -f "$compose" up -d --force-recreate "$container" >/dev/null 2>&1; then
        echo "  + container recreated"
    else
        # Try without service-name (some compose layouts have one service per file)
        if $DOCKER_CMD compose -f "$compose" up -d --force-recreate >/dev/null 2>&1; then
            echo "  + container recreated (whole compose)"
        else
            echo "  ! recreate failed -- run manually: $DOCKER_CMD compose -f $compose up -d --force-recreate"
            continue
        fi
    fi

    # Reconnect optional shared network
    if [[ -n "$SHARED_NETWORK" ]]; then
        $DOCKER_CMD network connect "$SHARED_NETWORK" "$container" 2>/dev/null || true
    fi
done

echo ""
echo "> Verification:"
for name in "${AGENT_LIST[@]}"; do
    [[ -z "$name" ]] && continue
    name="$(echo "$name" | xargs)"
    container=$(echo "$CONTAINER_TPL" | sed "s|\$NAME|$name|g")
    container="${container//\$NAME/$name}"
    if $DOCKER_CMD exec "$container" sh -c "touch ${CONTAINER_PATH}/.write-test && rm ${CONTAINER_PATH}/.write-test && echo writable" 2>&1 | sed "s/^/  ${container}: /"; then
        :
    fi
done

echo ""
echo "+ ${MESH_PATH} mount applied to ${#AGENT_LIST[@]} agent(s)"
