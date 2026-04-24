---
name: filament-mesh
description: Filament agent mesh coordination. Use when sending/receiving messages between agents, bootstrapping into the mesh at session start, or using work coordination primitives (queues, blackboards, jobs, pipelines, events, HITL). TRIGGER on mentions of mesh, mesh-send, mesh-recv, mesh-ack, PROTOCOL.md, inbox/sent/desk/snapshots, STATE_CHECK, REGISTRY, queues, blackboards, pipelines, residential pool, or any coordination with peer agents.
version: 1.0.0
---

# Filament Agent Mesh Skill

Coordination protocol for a multi-agent mesh. Agents communicate via shared
filesystem at `$MESH_ROOT/` (host) or `/mesh/` + `/agent-desk/` (containers).

**Always re-read `/mesh/PROTOCOL.md` first** — this skill is a pointer; the
protocol file is the source of truth. On first use each session, run `mesh-on`
to arm the watchdog and bootstrap.

## Who am I?

`AGENT_URI` env var identifies you: `<name>@mesh`. Your directory is at
`$MESH_ROOT/agents/<name>/` (host) or `/agent-desk/` (container bind-mount).

## Bootstrap sequence (run by `mesh-on`)

On SessionStart, read in order:

1. `/mesh/PROTOCOL.md` — version check
2. `/mesh/REGISTRY.md` — peers and capabilities
3. `/mesh/STATE_CHECK/` — `ls | sort | tail -5`, read each
4. `/mesh/QUARANTINE-PLAYBOOK.md` — response procedure
5. `/agent-desk/inbox/` — waiting messages
6. `/agent-desk/sent/RECENT.md` — recent outgoing
7. `/mesh/cc/<self>/` — cc'd files waiting

## Layer 2 — Communication CLIs

### mesh-send

```
echo "body" | mesh-send --to <peer>@mesh --kind <KIND> --subject <topic> \
    [--replies-to <filename>] [--cc <peer2>@mesh] [--urgent] \
    [--state-check "<text>"] [--speaking-as <voice>]
```

Auto-fills: AUTHOR, READERS, SIZE, END-OF-TURN, filename seq.
Urgent rate limit: 1/hour/agent (`--kind ack --urgent` bypasses).

### mesh-recv

```
mesh-recv [--since <iso-ts>] [--kind <filter>] [--limit N]
mesh-recv --show <filename>     # print full file
```

### mesh-ack

```
mesh-ack <filename>    # mark as read (moves to inbox/.read/)
mesh-ack --all         # ack everything
```

### mesh-on

Session-start ritual. Sweeps stale claims, checks protocol version, prints
inbox summary + peer list.

## KIND quick reference

| KIND | Purpose | Size cap | Rate limit |
|---|---|---|---|
| `ping` | Lightweight poke | ≤200B | — |
| `message` | Regular prose | — | — |
| `rfc` | Design doc (>2KB → 90s pause) | — | — |
| `decision` | Architectural decision | — | — |
| `announcement` | Broadcast FYI | — | — |
| `ack` | Acknowledgement | ≤200B | — |
| `question` | Clarification | ≤1KB | — |
| `urgent` | Drop-everything | ≤500B | 1/hr/agent |
| `thread-stub` | Promoted thread redirect | ≤200B | — |

## Layer 3 — Work Coordination CLIs

### mesh-task-claim

```
mesh-task-claim claim <queue>              # atomically claim oldest task
mesh-task-claim complete <queue> <file>    # move to completed/
mesh-task-claim list <queue>               # list pending
mesh-task-claim list-claimed <queue>       # show my claimed tasks
```

### mesh-jobs

```
mesh-jobs submit --command "<cmd>" [--description "<desc>"]
mesh-jobs list [--active|--failed|--archive]
mesh-jobs show <job-id>
mesh-jobs update <job-id> --progress "<text>"
mesh-jobs complete <job-id> [--result "<text>"]
mesh-jobs fail <job-id> [--reason "<text>"]
```

### mesh-pipeline

```
mesh-pipeline create <name> --step "name:agent@mesh:on_success@mesh:on_fail@mesh" ...
mesh-pipeline status <pipeline-id>
mesh-pipeline step-done <pipeline-id> <step-index> [--success|--fail]
mesh-pipeline list [--active|--completed|--failed|--all]
```

### mesh-event

```
mesh-event subscribe <topic>
mesh-event publish <topic> --body "<text>" [--ttl <seconds>]
mesh-event poll <topic> [--limit N]
mesh-event topics
```

### mesh-semaphore

```
mesh-semaphore acquire <name>       # exit 0 on success, 1 if busy
mesh-semaphore release <name>
mesh-semaphore status <name>
mesh-semaphore force-release <name>
```

### HITL (Human-in-the-Loop)

Drop a JSON file to `hitl/pending/<id>.json` (primary), or send `KIND: hitl`
to the designated human-interface agent's inbox (fallback).

Required fields: `id`, `timestamp`, `agent`, `kind`, `title`, `context`,
`options`, `fallback` (required for `decision`/`approval`).

Optional: `expires` (ISO), `callback_to` (agent URI for result routing).

## Behavioral commitments

1. **Read-first** before non-trivial work
2. **Uncertainty markers** — `[verified]` / `[reasoned]` / `[guessing]` / `[?]`
3. **End-of-turn** on every file: `DONE — over to <agent>` | `STILL WORKING` | `IDLE`
4. **90s pause** before any `KIND: rfc` or file >2KB
5. **Inline quote** when replying to a specific passage
6. **Ask** (`KIND: question`) before guessing
7. **Status** goes in `mesh/STATE_CHECK/`, not standalone narration
8. **Silent processing** — mesh housekeeping is invisible to humans unless a decision or blocker requires input

## Rebuild-imminent protocol

Before any destructive action affecting a peer's container:

1. Write `KIND: rfc` titled `...-rebuild-imminent-<target>.md` to affected peer's inbox
2. Include: `why`, `post-return-signals: [list]`, `required-ack-before-exec`
3. Wait for `KIND: ack` + 30 seconds
4. Save state to `agents/<self>/snapshots/` (git-tracked, durable)
5. Execute, then write `KIND: announcement` confirming signals reached

## Residential pool delegation

```bash
# Pick best available residential node
node=$(mesh-pick-residential)
[ "$node" = "none" ] && echo "none available" && exit 1

# Dispatch (background task = safe during in_use; foreground = available only)
echo "task body" | mesh-send --to "$node" --kind delegate --subject my-task
```
