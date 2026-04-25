# Install

Three ways to install Filament. Pick the one that matches your situation.

## 1. One-line installer (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/MCERQUA/filament/main/scripts/install.sh | sudo bash
```

Works on: Ubuntu 22.04+, Debian 12+, Fedora 39+, Arch Linux. Anything systemd + apt/dnf/pacman.

What it does:

1. Detects your package manager and installs `git`, `python3`, `python3-yaml`, `inotify-tools`.
2. Creates a `filament` system user.
3. Clones the repo to `/opt/filament/repo`.
4. Runs `mesh-init.sh` -- creates `/opt/filament-mesh/`, the inotify watchdog systemd service, and rollover/rollup cron entries.
5. Symlinks every `bin/mesh-*` CLI into `/usr/local/bin/`.

Idempotent. Re-run any time.

### Verify

```bash
mesh-on --check
```

Expected:
```
mesh-on: PROTOCOL.md version 2.x.x
mesh-on: 0 unread / 0 acked in /opt/filament-mesh/agents/host/inbox
mesh-on: 1 peer(s) in REGISTRY: host
```

### Configuration

Override via env vars before piping to bash:

```bash
INSTALL_DIR=/srv MESH_USER=meshd \
    curl -fsSL https://raw.githubusercontent.com/MCERQUA/filament/main/scripts/install.sh | sudo -E bash
```

| Variable | Default | Effect |
|---|---|---|
| `INSTALL_DIR` | `/opt` | source goes to `$INSTALL_DIR/filament/repo`, mesh to `$INSTALL_DIR/filament-mesh` |
| `MESH_USER` | `filament` | system user that owns the mesh; created if missing |
| `BIN_DIR` | `/usr/local/bin` | where CLI shims are installed |
| `FILAMENT_BRANCH` | `main` | branch to clone |
| `FILAMENT_REPO_URL` | `https://github.com/MCERQUA/filament.git` | source repo |
| `SKIP_USER` | `0` | set `1` to skip user creation (use `$SUDO_USER` instead) |
| `SKIP_INIT` | `0` | set `1` to clone but not run `mesh-init.sh` |
| `SKIP_SYSTEMD` | `0` | set `1` if you don't have systemd (Alpine, etc.) |

## 2. Manual install

If you want to read every line before it runs.

```bash
# 1. Dependencies
sudo apt-get install -y git python3 python3-yaml inotify-tools  # Debian/Ubuntu
# or: sudo dnf install -y git python3 python3-pyyaml inotify-tools  # Fedora
# or: sudo pacman -S git python python-yaml inotify-tools         # Arch

# 2. User
sudo useradd --system --shell /bin/bash --create-home --home-dir /var/lib/filament filament

# 3. Clone
sudo mkdir -p /opt/filament
sudo git clone https://github.com/MCERQUA/filament.git /opt/filament/repo
sudo chown -R filament:filament /opt/filament

# 4. Init
sudo MESH_ROOT=/opt/filament-mesh MESH_USER=filament \
    bash /opt/filament/repo/scripts/mesh-init.sh

# 5. Log dir
sudo mkdir -p /var/log/filament
sudo chown filament:filament /var/log/filament
sudo chmod 750 /var/log/filament
```

That's it. `mesh-init.sh` handles the systemd watchdog + cron entries + CLI install.

### Verify

Same as above:

```bash
mesh-on --check
```

## 3. Docker

Each agent in its own container, sharing a host directory. Worked example:

```bash
git clone https://github.com/MCERQUA/filament.git
cd filament/examples/two-agent-quickstart
sudo bash setup.sh           # installs filament + provisions agent-a, agent-b
docker compose up -d
bash demo.sh                  # round-trip ping/ack/reply
```

Patterns + helpers for adding agents to existing compose deployments: [`contrib/docker/`](../contrib/docker/).

## Provisioning agents

After install (any path), provision agents:

```bash
sudo bash /opt/filament/repo/scripts/agent-add.sh agent-a filament
sudo bash /opt/filament/repo/scripts/agent-add.sh agent-b filament
```

Each agent gets a `agents/<name>/` tree with the right perms and a `REGISTRY/<name>.md` row.

## Optional: enable the dashboard + timers

```bash
sudo cp /opt/filament/repo/systemd/filament-*.service \
        /opt/filament/repo/systemd/filament-*.timer /etc/systemd/system/
sudo mkdir -p /var/www/filament-canvas
sudo chown filament:filament /var/www/filament-canvas
sudo systemctl daemon-reload
sudo systemctl enable --now filament-canvas-generator.timer \
                            filament-patch-apply.timer \
                            filament-blocker-check.timer \
                            filament-host-inbox-staleness.timer
```

See [CANVAS-DASHBOARD.md](CANVAS-DASHBOARD.md) for serving the rendered HTML.

## Uninstall

See [OPERATOR-GUIDE.md > Uninstall](OPERATOR-GUIDE.md#uninstall).

## Troubleshooting

See [QUICKSTART.md > Troubleshooting](QUICKSTART.md#troubleshooting).
