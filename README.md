# Filament

**Filesystem-first multi-agent coordination framework.**

No broker. No database. No central server. A mounted directory and a handful of CLIs.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Protocol v2.x](https://img.shields.io/badge/protocol-v2.x-green.svg)](PROTOCOL.md)
[![Repo](https://img.shields.io/badge/github-MCERQUA%2Ffilament-black.svg)](https://github.com/MCERQUA/filament)

---

## Why

- **Concurrent AI agents need to coordinate** -- send messages, agree on decisions, claim work, share blackboards. Most projects build this from scratch every time.
- **Filesystems are the most reliable bus you have access to.** POSIX `mkdir` gives atomic claims. `mtime` gives liveness. Markdown gives auditability. Git gives the audit log for free.
- **No vendor lock-in.** Anything that can move files (Docker bind-mounts, Tailscale, SSH, NFS, S3FS) can carry Filament traffic. The framework is unaware of the transport.

If you can `ls` it, you can debug it.

## Quick install

```bash
curl -fsSL https://raw.githubusercontent.com/MCERQUA/filament/main/scripts/install.sh | sudo bash
```

Then provision two agents and send your first message:

```bash
sudo bash /opt/filament/repo/scripts/agent-add.sh agent-a filament
sudo bash /opt/filament/repo/scripts/agent-add.sh agent-b filament

export AGENT_URI=agent-a@mesh
export MESH_ROOT=/opt/filament-mesh
echo 'hello agent-b' | mesh-send --to agent-b@mesh --kind ping --subject hello

AGENT_URI=agent-b@mesh mesh-recv
```

Full walkthrough: [docs/QUICKSTART.md](docs/QUICKSTART.md). Containerized version: [examples/two-agent-quickstart/](examples/two-agent-quickstart/).

## How it works

Filament organizes coordination into four independently-usable layers, each backed by a directory:

```
L3  Active Coordination   QUEUE/  JOBS/  PIPELINES/  SEMAPHORES/
L2  Events & Broadcast    EVENTS/  BROADCAST/  BLACKBOARD/  cc/
L1  Direct Messaging      agents/<name>/inbox/  agents/<name>/sent/  DEAD_LETTER/
L0  Liveness              REGISTRY/  HEARTBEAT/  STATE_CHECK/
```

Every primitive is a Markdown file. Atomic `mkdir` claims allocate slots without locks. An inotify watchdog (with a 5-second polling fallback) fires consumers in near-real-time. Nothing is ever deleted by the protocol -- TTL and archive handle retention, so the git history of `MESH_ROOT` is the audit trail.

A bundled MCP server (`mcp-server/`) exposes every primitive as a tool, making any MCP-capable AI agent (Claude Code, Cursor, etc.) a first-class mesh citizen.

The full wire format -- message headers, kinds, lifecycle, security model -- is in [PROTOCOL.md](PROTOCOL.md).

## What's in the box

| Directory | Contents |
|---|---|
| [`bin/`](bin/) | The CLIs (`mesh-send`, `mesh-recv`, `mesh-ack`, `mesh-event`, `mesh-chat`, `mesh-jobs`, `mesh-semaphore`, `mesh-pipeline`, `mesh-blocker`, ...) |
| [`scripts/`](scripts/) | Operator scripts (init, agent-add, rollover, rollup, blocker check, patch apply, nightly reflection, canvas dashboard) |
| [`systemd/`](systemd/) | Service + timer units for every periodic operator script |
| [`mcp-server/`](mcp-server/) | MCP server -- exposes every CLI as a tool to AI agents |
| [`skill/`](skill/) | Reusable agent skills (nightly reflection, more to come) |
| [`docs/`](docs/) | Documentation (this README points into it) |
| [`examples/`](examples/) | Working deployment examples |
| [`contrib/docker/`](contrib/docker/) | Docker patterns + helpers |

## Documentation

- **[QUICKSTART](docs/QUICKSTART.md)** -- 30-minute walkthrough, host install
- **[INSTALL](docs/INSTALL.md)** -- one-liner, manual, and Docker install paths
- **[PROTOCOL](PROTOCOL.md)** -- the wire format and every directory's purpose
- **[OPERATOR-GUIDE](docs/OPERATOR-GUIDE.md)** -- everything you can run from the host
- **[CANVAS-DASHBOARD](docs/CANVAS-DASHBOARD.md)** -- self-updating status page
- **[REFLECTION-PROTOCOL](docs/REFLECTION-PROTOCOL.md)** -- nightly multi-agent reflection cadence
- **[CAPABILITIES-SCHEMA](docs/CAPABILITIES-SCHEMA.md)** -- how agents publish their installed tools
- **[contrib/docker/README](contrib/docker/README.md)** -- Docker deployment patterns
- **[systemd/README](systemd/README.md)** -- timer unit installation + cron alternative

## Use cases

Filament is designed for any deployment with multiple AI agents that need to coordinate without a central service. Examples:

- **Per-customer agents** sharing platform-level wisdom (security findings, tool installs, protocol improvements) but never joint client work.
- **Multi-stage pipelines** -- research agent feeds a writer agent feeds a reviewer agent.
- **Stress-test fleets** -- N copies of the same agent contending for work via `mesh-queue`.
- **Heterogeneous nodes** -- a long-running orchestrator on a VPS, ephemeral laptop nodes, mobile phones with intermittent connectivity. The same files work for everyone.
- **Embedded into existing systems** -- if your orchestration today is "scripts that produce files in a known place," Filament probably already maps to your mental model.

## Master Checklist (post-install verification)

Single source of truth: `/mnt/agent-mesh/mesh/BLACKBOARD/master-checklist/LATEST.md`
Mirror: `/home/mike/filament/docs/MASTER-CHECKLIST.md`
JamBot copy: `/home/mike/MIKE-AI/docs/jambot/mesh-master-checklist.md`

23-section checklist (A-W) covering directory tree, CLIs, protocol compliance,
watchdog/heartbeat, cron+timer, Layer 3, residential pool, HITL, patch/blocker
flow, canvas dashboard, capabilities, security, decisions/RFC voting, rebuild
protocol, bootstrap, nightly reflection, MCP server, agent-side empowerment,
onboarding, backups, doc routing, observability, gotchas. Run after every
fresh install or major upgrade.

## Status

Filament is in active use. The protocol is stable at v2.x; CLIs and operator scripts are stable. The MCP server, canvas dashboard, and patch-apply workflow are newer (April 2026) and continue to evolve.

We accept agent-submitted patches via the same `KIND:patch` flow that runs in production -- see [CONTRIBUTING.md](CONTRIBUTING.md) for the recursive case where agents on a Filament mesh contribute back to Filament itself.

## Contributing

PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

Issues: <https://github.com/MCERQUA/filament/issues>

## License

MIT -- see [LICENSE](LICENSE).
