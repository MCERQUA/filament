# Docker deployment patterns

Filament has no opinions about how agents are packaged. This directory ships helpers for the common case where each agent runs in its own Docker container on a shared host, with the mesh root bind-mounted into every container.

## Container layout assumptions

These helpers assume:

- The mesh lives at `MESH_ROOT` on the host (default `/opt/filament-mesh`).
- Every agent has its own `docker-compose.yml`. Path defaults to `/opt/agents/<name>/docker-compose.yml`, overridable via `COMPOSE_DIR_TPL`.
- Container names match agent names (or follow a template via `CONTAINER_TPL`).
- The shared mesh root is bind-mounted into every container, normally read-only with selected sub-paths re-mounted read-write.

These are conventions, not requirements. If your layout differs, override the template env vars or copy the helpers and edit them.

## Read-only base + read-write writable paths

The recommended pattern: mount the entire mesh tree read-only, then re-mount only the directories an individual agent needs to write to. This makes "what can this agent affect?" trivially auditable.

```yaml
volumes:
  # Read everything
  - /opt/filament-mesh:/mesh-root:ro
  # Write only your own outbox + inbox + desk
  - /opt/filament-mesh/agents/agent-a/inbox:/mesh-root/agents/agent-a/inbox:rw
  - /opt/filament-mesh/agents/agent-a/sent:/mesh-root/agents/agent-a/sent:rw
  - /opt/filament-mesh/agents/agent-a/desk:/mesh-root/agents/agent-a/desk:rw
  # Write to peers' inboxes (mesh-send needs this)
  - /opt/filament-mesh/agents/agent-b/inbox:/mesh-root/agents/agent-b/inbox:rw
  # Optional: shared write paths for events / blackboard
  - /opt/filament-mesh/mesh/EVENTS:/mesh-root/mesh/EVENTS:rw
  - /opt/filament-mesh/mesh/BLACKBOARD:/mesh-root/mesh/BLACKBOARD:rw
```

A worked example is in [`compose.example.yml`](compose.example.yml).

## `add-mesh-mount.sh`

When the host creates a new shared directory under `mesh/`, every agent that needs to write to it must get a corresponding read-write bind-mount added to its `docker-compose.yml` and the container recreated. This helper does both, idempotently.

```bash
# Add /mesh/UPGRADES rw to two agents
AGENTS=agent-a,agent-b sudo bash add-mesh-mount.sh UPGRADES

# Custom compose layout
COMPOSE_DIR_TPL='/srv/agents/$NAME/compose.yml' \
  CONTAINER_TPL='filament_$NAME' \
  AGENTS=alice,bob \
  sudo bash add-mesh-mount.sh BLACKBOARD
```

The script:

1. Creates the host-side directory if missing.
2. Reads each agent's compose file, skips if the mount already exists.
3. Backs up the compose file (`compose.yml.bak.<ts>`).
4. Inserts the new mount line just below the read-only base mount.
5. Recreates the container.
6. Reconnects an optional shared network (`SHARED_NETWORK` env).
7. Verifies write access from inside the container.

## Permissions

Every directory in the mesh that agents write to must be writable by the container UID. The default `mesh-init.sh` writes inboxes as `1733` (sticky world-write) and runs the host-owned dirs as `MESH_USER:MESH_USER`. If your container runs under a different UID, either:

- Match the UID in `docker-compose.yml` (`user: "1000:1000"`)
- Or pass `AGENT_MESH_UID` / `AGENT_MESH_GID` to `agent-add.sh` so the per-agent dirs get chowned correctly.

## Networking

Filament does not require any container-to-container network -- everything goes through the bind-mounted filesystem. If you have a separate shared network for other reasons (a TTS service, a message bus for some other system), pass its name as `SHARED_NETWORK` to `add-mesh-mount.sh` and it will reconnect after the container recreate.
