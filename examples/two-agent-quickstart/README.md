# Two-agent quickstart

The smallest possible Filament deployment: two Ubuntu containers on a single host, sharing one mesh root, sending each other messages.

## What it shows

- Two agents (`agent-a`, `agent-b`) running in separate Docker containers.
- Both containers bind-mount the same host directory (`/opt/filament-mesh`) so the filesystem is the bus.
- Each container can write its own `inbox/`, `sent/`, `desk/` plus the *other agent's* `inbox/` (so `mesh-send` can deliver).
- A complete round-trip: agent-a sends a ping, agent-b receives + acks + replies, agent-a sees the reply.

This is the minimal end-to-end test that the protocol works on your host.

## Prerequisites

- Linux host with Docker and Docker Compose v2.
- `sudo` access (one-time, for `setup.sh`).
- Ports: none. Filament uses no network -- only the filesystem.

## Run it

```bash
# 1. Install filament + provision the two agent slots (host side, one-time)
sudo bash setup.sh

# 2. Start the containers
docker compose up -d

# 3. Send a message round-trip
bash demo.sh
```

Expected last lines of `demo.sh`:

```
+ round-trip complete.
  agent-a sent/:
    2026-04-25T...-ping-hello-from-agent-a.md
  agent-b sent/:
    2026-04-25T...-reply-pong-from-agent-b.md
```

## What just happened

`setup.sh`:

1. Ran the filament installer (creates `/opt/filament-mesh/`, installs `mesh-*` CLIs to `/usr/local/bin/`, creates the `filament` system user).
2. Called `agent-add.sh` for each agent (creates `agents/agent-a/{inbox,sent,desk,snapshots}/` with the right permissions, writes a `REGISTRY/agent-a.md` row).

`docker compose up -d`:

1. Started two containers with the host's `/opt/filament-mesh` bind-mounted at `/mesh` (read-only).
2. Re-mounted each agent's own writable directories read-write.
3. Cross-mounted the *other* agent's `inbox/` read-write (so `mesh-send` can deliver).

`demo.sh`:

1. `agent-a` ran `mesh-send --to agent-b@mesh ...`, which dropped a `.md` file into `/mesh/agents/agent-b/inbox/`.
2. `agent-b` ran `mesh-recv`, which read the file.
3. `agent-b` ran `mesh-ack`, which moved the file to `/mesh/agents/agent-b/inbox/.read/`.
4. `agent-b` ran `mesh-send --to agent-a@mesh ...`, the same flow in reverse.

No broker, no daemon, no network calls.

## Extending

Add a third agent:

```bash
# Host side
sudo bash ../../scripts/agent-add.sh agent-c filament

# Add a service block in docker-compose.yml mirroring agent-a / agent-b.
# Cross-mount agent-c's inbox into a/b and a/b's inboxes into c.

docker compose up -d
```

Try the higher layers:

```bash
# Pub/sub (Layer 2)
docker exec filament-agent-a bash -c '
    AGENT_URI=agent-a@mesh MESH_ROOT=/mesh mesh-event subscribe build.events
'
docker exec filament-agent-b bash -c '
    AGENT_URI=agent-b@mesh MESH_ROOT=/mesh mesh-event publish build.events \
        --subject "build started" <<< "stage=compile"
'

# Distributed locks (Layer 3)
docker exec filament-agent-a bash -c '
    AGENT_URI=agent-a@mesh MESH_ROOT=/mesh mesh-semaphore acquire deploy --timeout 5
'
```

## Cleanup

```bash
docker compose down
# Optional: nuke the mesh state (keeps install otherwise)
sudo rm -rf /opt/filament-mesh
```

The `/usr/local/bin/mesh-*` CLIs and `/var/log/filament/` stay around -- re-run `setup.sh` to rebuild the mesh.
