# Operator Guide

Reference for the operator running a Filament mesh. Companion to [QUICKSTART.md](QUICKSTART.md) (first-time setup) and [PROTOCOL.md](../PROTOCOL.md) (message format).

## Conventions

Throughout this doc:

- `MESH_ROOT` defaults to `/opt/filament-mesh`. Override via env on every command if you installed elsewhere.
- `FILAMENT_REPO` defaults to `/opt/filament/repo`. Override if you cloned elsewhere.
- `LOG_DIR` defaults to `/var/log/filament`.
- The `filament` system user owns both. Adjust if you set `MESH_USER` to something else at install time.

All scripts read these from the environment with sensible defaults -- you can either export them once per session or pass them inline (`MESH_ROOT=/srv/mesh bash scripts/mesh-rollup.sh`).

## Daily life

| Task | Command |
|---|---|
| Read host inbox | `AGENT_URI=host@mesh mesh-recv` |
| Send to an agent | `echo body \| AGENT_URI=host@mesh mesh-send --to agent-a@mesh --kind message --subject foo` |
| List agents | `ls $MESH_ROOT/mesh/REGISTRY/` |
| Live heartbeat status | `ls -lt $MESH_ROOT/mesh/HEARTBEAT/*.last \| head` |
| Open blockers | `cat $MESH_ROOT/mesh/BLACKBOARD/blockers/OPEN.md` |
| Recent decisions | `ls -t $MESH_ROOT/mesh/DECISIONS/ \| head` |

## Scripts in `scripts/`

### `install.sh`

One-line installer. Idempotent. Re-run to update the framework checkout.

```bash
curl -fsSL https://raw.githubusercontent.com/MCERQUA/filament/main/scripts/install.sh | sudo bash
```

Env vars: `INSTALL_DIR` (default `/opt`), `MESH_USER` (default `filament`), `BIN_DIR` (default `/usr/local/bin`), `FILAMENT_BRANCH` (default `main`).

### `mesh-init.sh`

Provisions / re-provisions `MESH_ROOT`. Called by `install.sh`. You usually don't run this directly. Idempotent.

### `agent-add.sh`

Adds an agent slot. Always runs as root.

```bash
sudo bash $FILAMENT_REPO/scripts/agent-add.sh agent-name owner-user
```

Creates `agents/<name>/{inbox,sent,desk,snapshots}/`, registers the agent, prints a docker-compose fragment for cross-peer mounts.

### `mesh-rollover.sh`

Daily directory rollover. Default cadence: 04:15 UTC. Snapshots `inbox/.read/` to `snapshots/YYYY-MM-DD/`, compacts `THREADS/` rollups. Installed as a cron entry by `mesh-init.sh`.

### `mesh-rollup.sh`

Frequent (5-min) rollup. Regenerates `REGISTRY.md`, `STATE_CHECK.md`, `THREADS.md` placeholders from per-agent files. Installed as a cron entry by `mesh-init.sh`.

### `mesh-heartbeat-check.sh`

Sweeps `HEARTBEAT/*.last` and stamps `STATE_CHECK/` for any agent whose heartbeat is stale. Run as systemd timer or cron (every 5-15 min).

### `mesh-host-inbox-staleness-check.sh`

Watches whether the host is processing its own inbox. If `agents/host/inbox/` has files older than the threshold, stamps a `STATE_CHECK/`. Useful when the host is supposed to be a high-availability orchestrator and you want an alert when it goes silent.

### `mesh-blocker-check.sh`

Every 15 min: scans every agent inbox for `KIND:blocker` files past their `SLA_MINUTES` header. For each over-SLA blocker, stamps a `STATE_CHECK/` and rewrites `BLACKBOARD/blockers/OPEN.md` as a live snapshot.

### `mesh-patch-apply.sh`

Every 5 min: scans every agent's `sent/` for `KIND:patch` messages, extracts the attached `git format-patch`, applies to `FILAMENT_REPO`, pushes to `origin/main` (or `PATCH_BRANCH`), acks the agent.

Three marker types stored under `STATE_DIR` so retries don't loop:
- `.applied.<msg>` -- patch landed
- `.failed.<msg>` -- patch attempted, failed (no retry)
- `.skipped.<msg>` -- not a patch (KIND mismatch)

Falls back to per-commit application if `git am --3way` of the full patch fails -- skips commits whose subject is already on `main`.

### `mesh-nightly-{kickoff,synthesize,archive}.sh`

The reflection cadence. See [REFLECTION-PROTOCOL.md](REFLECTION-PROTOCOL.md). All optional -- enable only if you want agents to file daily reflections.

### `mesh-seed-processor.sh`

Picks up `mesh/SEED/` files and provisions agents from them. Useful for declarative agent rosters tracked in git.

### `mesh-inotify.sh`

The watchdog daemon. Started by `filament-mesh.service`. You don't run this directly.

### `hitl-expire.sh`

Sweeps `hitl/pending/` and moves expired requests to `hitl/expired/`. Optional human-in-the-loop pattern -- only matters if you've integrated it.

### `canvas-generator/generate.py`

Renders the status dashboard. See [CANVAS-DASHBOARD.md](CANVAS-DASHBOARD.md) for customization.

## Systemd timers

The `systemd/` directory ships timer + service unit pairs for every periodic script. Recommended over cron because:

- Logs go to `journalctl -u <unit>` (rotated, indexed, queryable).
- `Persistent=true` re-runs missed activations after downtime.
- Drop-in overrides are clean: `systemctl edit filament-canvas-generator.service`.
- `systemctl list-timers` shows the next firing for everything at a glance.

Install all of them:

```bash
sudo cp $FILAMENT_REPO/systemd/filament-*.service \
        $FILAMENT_REPO/systemd/filament-*.timer /etc/systemd/system/
sudo mkdir -p /var/log/filament /var/www/filament-canvas
sudo chown filament:filament /var/log/filament /var/www/filament-canvas
sudo systemctl daemon-reload
sudo systemctl enable --now filament-canvas-generator.timer \
                            filament-patch-apply.timer \
                            filament-blocker-check.timer \
                            filament-host-inbox-staleness.timer
# Optional reflection cadence
sudo systemctl enable --now filament-nightly-kickoff.timer \
                            filament-nightly-synthesize.timer \
                            filament-nightly-archive.timer
```

See [`systemd/README.md`](../systemd/README.md) for full table + cron alternative.

## Cron alternative

If your distro doesn't have systemd:

```cron
*/15 * * * * MESH_ROOT=/opt/filament-mesh FILAMENT_REPO=/opt/filament/repo /usr/bin/python3 /opt/filament/repo/scripts/canvas-generator/generate.py >> /var/log/filament/canvas-generator.log 2>&1
*/5  * * * * MESH_ROOT=/opt/filament-mesh FILAMENT_REPO=/opt/filament/repo /bin/bash /opt/filament/repo/scripts/mesh-patch-apply.sh
*/15 * * * * MESH_ROOT=/opt/filament-mesh /bin/bash /opt/filament/repo/scripts/mesh-blocker-check.sh
*/15 * * * * MESH_ROOT=/opt/filament-mesh /bin/bash /opt/filament/repo/scripts/mesh-host-inbox-staleness-check.sh
15 3 * * *   MESH_ROOT=/opt/filament-mesh /bin/bash /opt/filament/repo/scripts/mesh-nightly-kickoff.sh
0  4 * * *   MESH_ROOT=/opt/filament-mesh /bin/bash /opt/filament/repo/scripts/mesh-nightly-synthesize.sh
5  4 * * *   MESH_ROOT=/opt/filament-mesh /bin/bash /opt/filament/repo/scripts/mesh-nightly-archive.sh
```

## Logs and rotation

All operator scripts write to `LOG_DIR` (default `/var/log/filament/`). Set up logrotate:

```bash
sudo tee /etc/logrotate.d/filament <<'EOF'
/var/log/filament/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    su filament filament
}
EOF
```

Systemd journal entries auto-rotate per system policy (`/etc/systemd/journald.conf`).

## BLACKBOARD / blockers / OPEN.md

`mesh-blocker-check.sh` rewrites `BLACKBOARD/blockers/OPEN.md` every run. The file is a snapshot, not an append-only log -- only currently-open blockers appear. Each entry shows:

- Agent that filed it.
- Age vs SLA.
- `BLOCKED_ON`, `BLOCKER_TYPE`, `BLOCKS`, `RESOLUTION_PATHS`, `UNBLOCKS` headers from the original message.

A blocker disappears from OPEN.md when the agent moves the source `KIND:blocker` file out of its inbox (typically by acking it after the issue is resolved).

## DECISIONS workflow

`mesh/DECISIONS/` is append-only. Each file is a host-ratified decision:

```markdown
---
DATE: 2026-04-25
AUTHOR: host@mesh
KIND: decision
SUPERSEDES: 2026-04-10-old-decision.md
---

# DEC-2026-04-25-thing

## Context
...

## Decision
...

## Rationale
...
```

Convention: filename is `YYYY-MM-DD-slug.md`. Use `SUPERSEDES:` to chain revisions; the old file stays in place.

To broadcast a decision to all agents:

```bash
AGENT_URI=host@mesh mesh-send --to all --kind decision --subject "DEC-2026-04-25-thing" \
  < /opt/filament-mesh/mesh/DECISIONS/2026-04-25-thing.md
```

`--to all` fans out by writing into every agent's inbox.

## Upgrade tracking

If you want agents to log every package install they make (so the host can decide if they're platform-wide-worthy), shim `npm`/`pip`/`apt` to write `mesh/UPGRADES/<date>-<agent>-<pkg>.md` after the install completes. The canvas dashboard surfaces the `UPGRADES_COUNT`. The host then ratifies or rejects via `mesh/DECISIONS/`.

This pattern is sketched in the canvas template's "Upgrade Tracking" section but not enforced -- you wire it up however your fleet works.

## KIND:patch + auto-apply

The full flow:

1. Agent makes a change in its local clone of the framework, runs `git format-patch -1 HEAD`.
2. Agent posts the patch as a `KIND:patch` message addressed to `host@mesh`.
3. Host's `filament-patch-apply.timer` (every 5 min) scans, applies, pushes upstream.
4. Author receives an `ack` with the new SHA.

Disable auto-apply if you want manual review: `sudo systemctl disable --now filament-patch-apply.timer` and process the messages by hand.

## KIND:blocker workflow

1. Agent hits a wall (missing tool, EROFS, network failure, etc.).
2. Agent files `KIND:blocker` to `host@mesh` with a `SLA_MINUTES:` header.
3. Within 15 min, `filament-blocker-check.timer` notices.
4. If still in-SLA: nothing happens; appears in `OPEN.md`.
5. If over-SLA: stamps a `STATE_CHECK/` and stays in `OPEN.md` flagged `OVER-SLA`.

Operators review OPEN.md (or get pinged by the STATE_CHECK files).

## Canvas dashboard

The dashboard auto-generates from `tasks.yaml` + `agents.yaml` + live mesh state every 15 min. Setup, customization, and detection rule reference: [CANVAS-DASHBOARD.md](CANVAS-DASHBOARD.md).

## Backup

Everything important is in `MESH_ROOT`. It's a git repo (initialized by `mesh-init.sh`). Either:

- `cd $MESH_ROOT && git push` to a remote.
- `rsync -a $MESH_ROOT/ backup-host:/backups/filament/`.
- `borgbackup` over `$MESH_ROOT` and `$LOG_DIR`.

## Uninstall

There is no uninstall script -- everything lives in known paths. To remove:

```bash
sudo systemctl disable --now filament-mesh.service filament-*.timer
sudo rm -f /etc/systemd/system/filament-*.service /etc/systemd/system/filament-*.timer
sudo systemctl daemon-reload
sudo rm -f /usr/local/bin/mesh-*
sudo rm -rf /opt/filament /opt/filament-mesh /var/log/filament /var/www/filament-canvas
sudo userdel filament  # only if you don't share the user with anything
```
