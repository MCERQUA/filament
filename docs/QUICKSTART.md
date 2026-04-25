# Quickstart

Get two agents talking in about 30 minutes.

This walkthrough assumes a single Linux host. If you want each agent in its own container, jump to [`examples/two-agent-quickstart/`](../examples/two-agent-quickstart/).

## Prerequisites

- Linux (any modern distro -- tested on Ubuntu 22.04+, Debian 12, Fedora 39).
- `sudo` access for the install step (the mesh user owns `/opt/filament-mesh/`).
- `git`, `python3 >= 3.8`. The installer pulls these if missing.
- Optional: `inotify-tools` (kernel-driven watchdog instead of 5s polling).

## 1. Install

```bash
curl -fsSL https://raw.githubusercontent.com/MCERQUA/filament/main/scripts/install.sh | sudo bash
```

That command:

- Installs git + python3 + inotify-tools via your package manager.
- Creates a `filament` system user.
- Clones the framework to `/opt/filament/repo`.
- Runs `mesh-init.sh` -- creates `/opt/filament-mesh/` directory tree, writes the protocol, installs the inotify watchdog systemd service.
- Symlinks every `bin/mesh-*` CLI into `/usr/local/bin/`.

It is idempotent. Re-run any time to update.

Verify:

```bash
mesh-on --check
```

You should see something like:

```
mesh-on: PROTOCOL.md version 2.1.x
mesh-on: 0 unread / 0 acked in /opt/filament-mesh/agents/host/inbox
mesh-on: 1 peer(s) in REGISTRY: host
```

## 2. Provision two agents

```bash
sudo bash /opt/filament/repo/scripts/agent-add.sh agent-a filament
sudo bash /opt/filament/repo/scripts/agent-add.sh agent-b filament
```

Each call:

- Creates `/opt/filament-mesh/agents/<name>/{inbox,sent,desk,snapshots}/` with the right ownership and permissions.
- Writes `/opt/filament-mesh/mesh/REGISTRY/<name>.md`.
- Prints a docker-compose bind-mount fragment (ignore if you're not using containers).

## 3. Send your first message

```bash
export AGENT_URI=agent-a@mesh
export MESH_ROOT=/opt/filament-mesh

echo 'hello agent-b' | mesh-send --to agent-b@mesh --kind ping --subject hello
```

Output:

```
mesh-send: delivered to /opt/filament-mesh/agents/agent-b/inbox/2026-04-25T...-ping-hello.md
```

## 4. Receive it

```bash
AGENT_URI=agent-b@mesh mesh-recv
```

Output:

```
=== 2026-04-25T...-ping-hello.md
FROM: agent-a@mesh
KIND: ping
SUBJECT: hello

hello agent-b
```

## 5. Ack it

```bash
AGENT_URI=agent-b@mesh mesh-ack 2026-04-25T...-ping-hello.md
```

The file moves from `inbox/` to `inbox/.read/`. You can re-read with `mesh-recv --read`.

## 6. Optional: enable the dashboard + timers

If you want auto-applied patches, blocker SLA sweeps, and the live status dashboard:

```bash
sudo cp /opt/filament/repo/systemd/filament-*.service \
        /opt/filament/repo/systemd/filament-*.timer \
        /etc/systemd/system/
sudo mkdir -p /var/log/filament /var/www/filament-canvas
sudo chown filament:filament /var/log/filament /var/www/filament-canvas
sudo systemctl daemon-reload
sudo systemctl enable --now filament-canvas-generator.timer \
                            filament-patch-apply.timer \
                            filament-blocker-check.timer \
                            filament-host-inbox-staleness.timer
```

Point any web server at `/var/www/filament-canvas/index.html`. With nginx:

```nginx
server {
    listen 80;
    server_name filament.example.com;
    root /var/www/filament-canvas;
    index index.html;
    add_header Cache-Control "no-store";  # this is a live dashboard
}
```

## Where to go next

- [PROTOCOL.md](../PROTOCOL.md) -- the message format, every directory's purpose, the four layers.
- [OPERATOR-GUIDE.md](OPERATOR-GUIDE.md) -- everything you can run from the host.
- [CANVAS-DASHBOARD.md](CANVAS-DASHBOARD.md) -- customizing the dashboard.
- [REFLECTION-PROTOCOL.md](REFLECTION-PROTOCOL.md) -- nightly multi-agent reflection workflow.
- [`examples/two-agent-quickstart/`](../examples/two-agent-quickstart/) -- the same quickstart but containerized.

## Troubleshooting

**`mesh-on --check` says `MESH_ROOT not set`**: `export MESH_ROOT=/opt/filament-mesh` (or use whatever path you passed as `INSTALL_DIR`).

**`mesh-send: permission denied`**: the recipient agent's `inbox/` isn't writable by your user. `agent-add.sh` sets `1733` (sticky world-write) which works for everyone -- check that ran successfully.

**Watchdog doesn't fire**: confirm `systemctl status filament-mesh.service`. If it's running but not picking up new files, check whether `inotify-tools` is installed (`which inotifywait`) -- without it the watchdog falls back to a 5s poll.

**`mesh-recv` says `(no messages)` even though I just sent one**: the watchdog hasn't fired yet (5s poll fallback) or the file went to the wrong inbox. Check `ls /opt/filament-mesh/agents/<recipient>/inbox/` directly.
