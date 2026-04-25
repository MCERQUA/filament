# Keepers — Active Mesh Oversight

The watcher reports state. The **keeper** makes things happen.

## The problem keepers solve

Watchers are passive. They stamp STATE_CHECK, generate rollups, log
progress. They do not drop tasks. They do not enforce.

For autonomous agent fleets running over hours/days, passive monitoring
is insufficient. Tmux + Claude Code agents wait on inbox arrivals — once
their initial task completes, they stay alive but produce nothing. Without
something actively dropping fresh tasks into their inboxes, work stalls
silently.

## Keeper architecture

`scripts/mesh-keeper.sh` runs every 15 min via cron. It iterates every
`scripts/keepers/<workstream>.sh` policy script and invokes its decision
function. Each policy decides:

1. Per-agent expected progress signal (commit, file, status update)
2. Stall threshold (workstream-specific — 30 min for hackathon, 6 h for blockers)
3. Re-drop interval (rate-limit between active prompts)
4. Escalation count (after N consecutive re-drops with no response, ping host)

## Helpers (exported by mesh-keeper.sh)

- `redrop_task <agent> <subject> <body-file>` — drop a fresh KIND:task into
  agent's inbox. Inbox monitor fires; agent picks it up next session.
- `escalate <agent> <reason>` — drop a KIND:announcement into host inbox.
- `touch_redrop <agent> <subject>` — record re-drop happened (auto-called by
  redrop_task).
- `redrop_count <agent> <subject>` — return consecutive re-drop count (resets
  on agent progress).
- `last_redrop <agent> <subject>` — epoch seconds of last re-drop.
- `reset_redrop <agent> <subject>` — clear counters when agent moves.

## State

`mesh/keepers/state/<agent>.<subject>.{redrops,last-redrop}` — small text
files; survive restarts; readable by anyone, written by host.

## Shipped policies

| Policy | Cadence | Stall threshold | Escalates after |
|---|---|---|---|
| `keepers/hackathon.sh` | every keeper run | 30 min repo silence | 4 re-drops |
| `keepers/nightly-reflection.sh` | every keeper run, post-18:00 UTC | 30 min after synthesis cron | 6h cooldown |
| `keepers/blockers.sh` | every keeper run | always (looks at OPEN.md) | 6h re-drop |

## Adding a new policy

1. Create `scripts/keepers/<name>.sh`
2. Use the exported helpers
3. Use `last_redrop` / cooldown to rate-limit
4. Make it idempotent — keeper runs every 15 min
5. Stamp STATE_CHECK if you want canvas dashboard visibility

## What this is NOT

- NOT a replacement for agent-side `/mesh-start` skills — keepers complement
  them. Skills handle session bootstrap; keepers handle inter-session continuity.
- NOT a substitute for the watcher — watcher = read-only telemetry, keeper =
  enforcement.
- NOT a replacement for blocker-check / heartbeat-check passive crons — those
  still run; keepers add the active prompting layer on top.

## Why this matters

The 2026-04-25 hackathon failure (DEC-2026-04-25-autonomous-oversight-failure.md)
was the first overnight test of mesh autonomy. It failed because the entire
oversight architecture was passive. Keepers are the architectural fix.
