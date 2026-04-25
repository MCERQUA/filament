# Filament systemd units

Systemd timer + service units for the periodic operator scripts. Timers are more portable, log-friendly, and reboot-safe than crontab entries.

## What's here

| Service | Timer | Purpose |
|---|---|---|
| `filament-mesh.service` | (always-on) | inotify watchdog -- the only "long-running" service. Started by `mesh-init.sh`. |
| `filament-canvas-generator.service` | every 15 min | Render the status dashboard HTML. |
| `filament-patch-apply.service` | every 5 min | Auto-apply `KIND:patch` messages to the framework repo. |
| `filament-blocker-check.service` | every 15 min | Escalate over-SLA blockers to STATE_CHECK + BLACKBOARD. |
| `filament-nightly-kickoff.service` | daily 03:15 UTC | Dispatch nightly reflection task to every agent. |
| `filament-nightly-synthesize.service` | daily 04:00 UTC | Synthesize per-agent reflections into group.md. |
| `filament-nightly-archive.service` | daily 04:05 UTC | Append group.md to THREADS rollup. |
| `filament-host-inbox-staleness.service` | every 15 min | Alert when the host stops processing its own inbox. |

All services are `Type=oneshot` and run as user `filament`. Activation cadence is encoded in the matching `.timer` units.

## Install

These units assume:

- Filament checked out at `/opt/filament/repo` (`FILAMENT_REPO`)
- Mesh root at `/opt/filament-mesh` (`MESH_ROOT`)
- A user named `filament` who owns both
- Logs going to `/var/log/filament/`

The defaults match what `scripts/install.sh` provisions. If you installed elsewhere, edit the `Environment=` lines (or use a systemd drop-in: `systemctl edit filament-canvas-generator.service`).

```bash
# As root
sudo cp systemd/filament-*.service systemd/filament-*.timer /etc/systemd/system/
sudo mkdir -p /var/log/filament
sudo chown filament:filament /var/log/filament

sudo systemctl daemon-reload
sudo systemctl enable --now filament-canvas-generator.timer
sudo systemctl enable --now filament-patch-apply.timer
sudo systemctl enable --now filament-blocker-check.timer
sudo systemctl enable --now filament-host-inbox-staleness.timer
# Reflection cadence is optional -- only enable if you've set up nightly reflections
sudo systemctl enable --now filament-nightly-kickoff.timer
sudo systemctl enable --now filament-nightly-synthesize.timer
sudo systemctl enable --now filament-nightly-archive.timer
```

## Verify

```bash
systemctl list-timers 'filament-*'
systemctl status filament-canvas-generator.service
journalctl -u filament-patch-apply.service -n 50
tail -f /var/log/filament/mesh-patch-apply.log
```

## Customizing

To override an environment variable (e.g. point at a different `MESH_ROOT`):

```bash
sudo systemctl edit filament-canvas-generator.service
```

This opens an editor for a drop-in override at `/etc/systemd/system/filament-canvas-generator.service.d/override.conf`. Drop in:

```ini
[Service]
Environment=MESH_ROOT=/srv/my-mesh
Environment=CANVAS_OUT=/var/www/dashboard.html
```

Then `sudo systemctl daemon-reload && sudo systemctl restart filament-canvas-generator.timer`.

## Cron alternative

If your distro doesn't ship systemd (Alpine, BusyBox-based images, etc.), the same scripts work fine from cron:

```cron
# Every 15 min
*/15 * * * * MESH_ROOT=/opt/filament-mesh FILAMENT_REPO=/opt/filament/repo /usr/bin/python3 /opt/filament/repo/scripts/canvas-generator/generate.py >> /var/log/filament/canvas-generator.log 2>&1
*/5  * * * * MESH_ROOT=/opt/filament-mesh FILAMENT_REPO=/opt/filament/repo /bin/bash /opt/filament/repo/scripts/mesh-patch-apply.sh
*/15 * * * * MESH_ROOT=/opt/filament-mesh /bin/bash /opt/filament/repo/scripts/mesh-blocker-check.sh
15 3 * * *  MESH_ROOT=/opt/filament-mesh /bin/bash /opt/filament/repo/scripts/mesh-nightly-kickoff.sh
0  4 * * *  MESH_ROOT=/opt/filament-mesh /bin/bash /opt/filament/repo/scripts/mesh-nightly-synthesize.sh
5  4 * * *  MESH_ROOT=/opt/filament-mesh /bin/bash /opt/filament/repo/scripts/mesh-nightly-archive.sh
```
