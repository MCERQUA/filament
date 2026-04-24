# Filament

**A filesystem-first multi-agent coordination framework for AI systems.**

Filament is a protocol + toolset for connecting AI agents (Claude Code, autonomous scripts, desktop agents, remote nodes) into a single coherent mesh — using nothing but the filesystem, POSIX atomicity, and Markdown files.

No message broker. No database. No central server. A mounted directory and a handful of shell scripts are all you need.

---

## Why Filament?

Modern AI deployments involve multiple agents working in parallel — some in Docker containers, some on remote machines, some running voice interfaces, some handling desktop automation. Getting them to coordinate without building a bespoke service for every project is hard.

Filament solves this by making **the filesystem the bus**. Messages are files. Inboxes are directories. Atomic claims use `mkdir`. Everything is readable, git-trackable, and debuggable with `ls`.

**Design principles:**

- **No special infrastructure.** A bind-mounted directory is all agents share. Docker, Tailscale, SSH — any transport that can move files works.
- **POSIX atomicity.** `mkdir` is the only lock primitive. No advisory locks, no databases, no ZooKeeper.
- **Markdown everywhere.** Every message, job, pipeline, and heartbeat is a `.md` file. Read it with `cat`. Audit it with `git log`. No binary blobs.
- **Additive-only.** Agents write new files; nothing is deleted. The git history is the audit trail.
- **Two-layer architecture.** Layer 2 handles communication (messages, threads, broadcasts). Layer 3 handles work (queues, jobs, pipelines, events).
- **MCP-native.** A bundled MCP server exposes all mesh primitives as tools, making every MCP-capable AI agent a first-class mesh citizen.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Filament Mesh                           │
│                                                                 │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌────────────┐  │
│  │  Agent A │   │  Agent B │   │  Agent C │   │  Remote    │  │
│  │ (Docker) │   │ (Docker) │   │  (Host)  │   │   Node     │  │
│  └────┬─────┘   └────┬─────┘   └────┬─────┘   └─────┬──────┘  │
│       │              │              │                │          │
│  ─────┴──────────────┴──────────────┴────────────────┴──────── │
│                       /mnt/agent-mesh/                          │
│                                                                 │
│   Layer 2 — Communication                                       │
│   agents/<name>/inbox/   mesh/BROADCAST/   mesh/cc/            │
│   mesh/REGISTRY.md       mesh/STATE_CHECK/ mesh/THREADS/        │
│                                                                 │
│   Layer 3 — Work Coordination                                   │
│   mesh/QUEUE/   mesh/BLACKBOARD/   mesh/JOBS/    mesh/EVENTS/  │
│   mesh/PIPELINES/   mesh/SEMAPHORES/   mesh/HEARTBEAT/          │
│   hitl/pending/     mesh/DEAD_LETTER/                           │
└─────────────────────────────────────────────────────────────────┘
```

---

## Directory Layout

```
/mnt/agent-mesh/
├── mesh/
│   ├── PROTOCOL.md              ← Protocol spec (versioned, watched by all agents)
│   ├── REGISTRY/                ← Per-agent registration rows (atomic first-boot write)
│   │   └── <agent>.md
│   ├── REGISTRY.md              ← Cron-rolled-up agent roster
│   ├── STATE_CHECK/             ← Point-in-time state snapshots (append-safe)
│   │   └── YYYY-MM-DDTHHMMSSZ-<agent>.md
│   ├── STATE_CHECK.md           ← Cron rollup (latest 20 entries)
│   ├── BROADCAST/               ← To-all messages (READERS: [all])
│   ├── cc/                      ← CC fanout destination
│   │   └── <agent>/
│   ├── QUARANTINE/              ← Host-moved malformed messages
│   ├── QUARANTINE-PLAYBOOK.md   ← Host response procedure
│   ├── THREADS.md               ← Cron rollup of closed thread summaries
│   │
│   ├── QUEUE/<name>/            ← Named work queues
│   │   ├── pending/             ← Unclaimed tasks
│   │   ├── claimed/             ← In-progress tasks
│   │   └── completed/           ← Finished results
│   │
│   ├── BLACKBOARD/<namespace>/  ← Shared result boards
│   │   ├── LATEST.md            ← Most recent post (overwritten)
│   │   └── archive/             ← Previous posts
│   │
│   ├── JOBS/                    ← Background job tracker
│   │   ├── active/              ← Running jobs (updated in-place)
│   │   ├── archive/             ← Completed jobs
│   │   └── failed/              ← Failed jobs
│   │
│   ├── HEARTBEAT/               ← Agent liveness stamps
│   │   └── <agent>.last
│   │
│   ├── DEAD_LETTER/             ← Failed delivery queue
│   │   └── <agent>/
│   │
│   ├── SEMAPHORES/              ← Distributed locks
│   │   └── <name>.lock
│   │
│   ├── PIPELINES/<id>/          ← Multi-step workflows
│   │   ├── manifest.md
│   │   ├── step-N-result.md
│   │   └── log.md
│   │
│   └── EVENTS/<topic>/          ← Pub/sub topics
│       ├── subscribers.md
│       └── last-published.md
│
├── agents/
│   └── <agent>/
│       ├── inbox/               ← Peers write here
│       ├── sent/                ← Own outgoing (git-tracked)
│       ├── snapshots/           ← Durable self-state (git-tracked)
│       └── desk/                ← Private scratch (volatile, not git)
│
├── hitl/
│   ├── pending/                 ← Human-in-the-loop requests
│   ├── resolved/                ← Completed HITL items
│   └── expired/                 ← Timed-out HITL items
│
└── threads/
    └── YYYY-MM-DD-<slug>/       ← Promoted multi-message topics
```

---

## Components

### Layer 2 — Communication Protocol

The core messaging layer. Agents communicate by writing Markdown files into each other's `inbox/` directories.

#### Message Format

**Filename:** `YYYY-MM-DD-NNN-<sender>-<topic>.md`

- `NNN` — 3-digit zero-padded daily sequence, allocated via `mkdir` (POSIX-atomic)
- `<sender>` — agent name without `@mesh`
- `<topic>` — kebab-case descriptor

**Required frontmatter:**

```yaml
KIND: message
AUTHOR: agent-name@mesh
READERS: [recipient@mesh]
REPLIES-TO: null
SIZE: short
END-OF-TURN: "agent-name@mesh — next expected action"
```

**Optional frontmatter:**

```yaml
STATE_CHECK: "point-in-time snapshot text"
SPEAKING_AS: "mike-direct | orchestrator-relay | agent-a-on-behalf-of-agent-b"
THREAD: "threads/slug"
PROMOTED_TO: "threads/slug"
URGENT: true
```

#### Message KINDs

| KIND | Purpose | Size cap | Rate limit |
|---|---|---|---|
| `ping` | Lightweight poke / pointer | ≤200B | — |
| `message` | Regular prose (default) | — | — |
| `rfc` | Design doc >2KB; triggers 90s pre-publish pause | — | — |
| `decision` | Architectural decision, auto-appended to `mesh/DECISIONS/` | — | — |
| `announcement` | Broadcast-class FYI, no response expected | — | — |
| `ack` | Minimal acknowledgement | ≤200B | — |
| `question` | Short clarification request | ≤1KB | — |
| `urgent` | Drop-everything escalation | ≤500B | 1/hour/agent |
| `attachment` | Sidecar describing a binary payload of same base name | — | — |
| `quarantine` | Host flagging a malformed or abusive file | — | — |
| `thread-stub` | Redirect pointing to a promoted thread directory | ≤200B | — |

#### Atomic Sequence Slot Claim

`touch` is not atomic. Filament uses `mkdir` exclusively for seq-slot allocation:

```bash
date=$(date -u +%Y-%m-%d)
existing_max=$(ls -1 "${inbox}/${date}-"???"-"*.md 2>/dev/null \
    | sed -E 's/.*-([0-9]{3})-.*/\1/' \
    | sort -n | tail -1)
start=$((10#${existing_max:-0} + 1))
(( start < 1 )) && start=1

for n in $(seq -w "${start}" 999); do
    slot="${date}-${n}-${sender}-${topic}"
    if mkdir "${inbox}/${slot}.claim" 2>/dev/null; then
        write_frontmatter_and_body > "${inbox}/${slot}.md"
        rmdir "${inbox}/${slot}.claim"
        exit 0
    fi
done
```

Stale claim cleanup (SessionStart + helper preamble):

```bash
find <inbox-dir> -maxdepth 1 -type d -name '*.claim' -mmin +1 \
    -exec rmdir {} \; 2>/dev/null
```

#### Broadcast & CC

**Broadcast:** Write to `mesh/BROADCAST/` with `READERS: [all]`. Every agent reads this via their read-only `/mesh/` mount.

**CC:** Primary recipient gets the file in their `inbox/`. For each cc'd agent, the sender writes a copy to `mesh/cc/<cc-agent>/<filename>` — plain files, not symlinks, for Docker bind-mount compatibility. Every agent reads `mesh/cc/<self>/` via the `/mesh/` mount.

#### Thread Promotion

Single exchanges stay in inboxes. Promote to `threads/YYYY-MM-DD-<slug>/` when **any** of:
- ≥5 files in the topic cluster
- ≥3 distinct authors touched it
- >24h age from first message

Promotion is itself a `mkdir` atomic claim. Originals become `KIND: thread-stub` redirect files (never deleted).

#### Quarantine

The host agent moves malformed or AUTHOR-mismatched files to `mesh/QUARANTINE/`. The `QUARANTINE-PLAYBOOK.md` documents the response procedure. A cron audit runs every 15 minutes scanning for AUTHOR-field mismatches and malformed frontmatter.

---

### Layer 3 — Work Coordination

Work primitives layered on top of Layer 2. All additive — nothing in Layer 3 modifies Layer 2 semantics.

#### Task Queues

Named queues for work-stealing distribution. Multiple agents can watch the same queue; each task is claimed by exactly one.

**KINDs:** `task`, `task-result`

**Enqueue:**
```bash
# Write a KIND: task file to mesh/QUEUE/<name>/pending/
```

**Atomic claim (race-safe):**
```bash
queue="my-queue"
task_file="/mnt/agent-mesh/mesh/QUEUE/${queue}/pending/<filename>.md"
claim_slot="${task_file}.claim"

if mkdir "$claim_slot" 2>/dev/null; then
    mv "$task_file" "/mnt/agent-mesh/mesh/QUEUE/${queue}/claimed/$(basename $task_file)"
    # Append CLAIMED_BY + CLAIMED_AT to the file
    rmdir "$claim_slot"
else
    exit 1  # Another agent won the race
fi
```

**Task frontmatter fields:**
```yaml
KIND: task
QUEUE: "queue-name"
CLAIMED_BY: ""
CLAIMED_AT: ""
DEADLINE: ""
```

#### Blackboard

Shared result surface. Any agent posts; any agent reads. `LATEST.md` is always the most recent post; previous posts are archived.

**Post:**
```bash
# Write to mesh/BLACKBOARD/<namespace>/LATEST.md (atomic tmp→rename)
tmp="${target}.tmp"
write_content > "$tmp"
mv -f "$tmp" "$target"
```

**Use cases:** context sharing between voice agents and desktop agents, cross-agent state broadcast, coordination checkpoints.

#### Background Job Tracker

Agents submit long-running jobs and update them in-place. Other agents can poll status without messaging overhead.

**KIND:** `bg-job`

**Location:** `mesh/JOBS/active/<job-id>.md`

**Job frontmatter:**
```yaml
JOB_ID: "bg-abc123"
JOB_STATUS: "running"       # running | completed | failed | cancelled
JOB_PROGRESS: "Step 3/7"    # free-form
STARTED_AT: "2026-04-24T10:00:00Z"
ESTIMATED_DURATION: "15m"
```

**Atomic in-place update:**
```bash
tmp="${job_file}.tmp"
write_status > "$tmp"
mv -f "$tmp" "$job_file"
```

Completed/failed jobs move to `mesh/JOBS/archive/` or `mesh/JOBS/failed/`.

#### Heartbeat + Liveness

Each agent writes a liveness stamp to `mesh/HEARTBEAT/<agent>.last`. A host cron checks freshness every 5 minutes. If a stamp is >600 seconds old, the agent is considered OFFLINE.

**Standard heartbeat:**
```
timestamp: 2026-04-24T10:00:00Z
agent_uri: my-agent@mesh
hostname: my-container
uptime_sec: 3600
load_1m: 0.25
```

**Extended heartbeat for residential / external nodes:**
```
timestamp: 2026-04-24T10:00:00Z
agent_uri: residential-laptop@mesh
hostname: home-desktop
uptime_sec: 12830
load_1m: 0.35
node_status: available
active_task_id: null
next_scheduled_task: null
human_active_since: null
```

**Residential node states:**
- `available` — idle, no active tasks, safe to dispatch
- `in_use` — human is actively using the machine
- `busy` — running an agent-assigned task
- `offline` — unreachable (heartbeat stale ≥600s)
- `scheduled` — idle but a task is queued to start soon

#### Dead Letter Queue

Messages that fail delivery after retries land in `mesh/DEAD_LETTER/<agent>/`. Retry policies:

| Policy | Behavior |
|---|---|
| `on-availability` | Wait for the right resource (e.g. residential pool) |
| `on-restore` | Retry when peer comes back online |
| `deadline` | Drop if DEADLINE has passed |

When a residential node transitions to `available`, the heartbeat-check cron automatically replays tasks from `mesh/DEAD_LETTER/residential-pool/`.

#### Semaphores (Distributed Locks)

Mutex primitives for shared resources. Same `mkdir` atomicity as messaging.

**Acquire:**
```bash
claim="/mnt/agent-mesh/mesh/SEMAPHORES/${lock_name}.lock.claim"
lock="/mnt/agent-mesh/mesh/SEMAPHORES/${lock_name}.lock"

if mkdir "$claim" 2>/dev/null; then
    printf "HOLDER: %s\nACQUIRED_AT: %s\n" "$AGENT_URI" "$(date -u +%s)" > "$lock"
    rmdir "$claim"
fi
```

**Release:**
```bash
rm -f "$lock"
```

#### Pipelines

Linear multi-step workflows where each step is dispatched to a specific agent and routes to success/failure handlers.

**KIND:** `pipeline-step`

**Pipeline step frontmatter:**
```yaml
PIPELINE_ID: "pl-deploy-001"
STEP_INDEX: 1
STEP_COUNT: 4
STEP_NAME: "build-assets"
ON_SUCCESS: "deploy-agent@mesh"
ON_FAILURE: "host@mesh"
TIMEOUT: "30m"
```

Pipeline state machine: `CREATED → RUNNING → step-N-IN_PROGRESS → step-N-SUCCESS → step-N+1-CREATED → ... → COMPLETED`

Each pipeline has a `manifest.md` (step graph), per-step result files, and an append-only `log.md`.

#### Event Pub/Sub

Agents subscribe to named topics. Publishers broadcast to all subscribers via the `announcement` KIND.

**Subscribe:**
```bash
# Add agent URI to mesh/EVENTS/<topic>/subscribers.md
```

**Publish:**
```bash
# Send KIND: announcement to each subscriber's inbox
# Write mesh/EVENTS/<topic>/last-published.md
```

**Poll:**
```bash
# Read mesh/EVENTS/<topic>/last-published.md
# Compare with own last-read marker
```

#### Human-in-the-Loop (HITL)

Structured mechanism for agents to surface decisions, approvals, reviews, or alerts to a human operator — without blocking.

**KIND:** `hitl`, `hitl-result`

**Request body (JSON in fenced block):**
```json
{
  "id":         "20260424T123456",
  "timestamp":  "2026-04-24T12:34:56Z",
  "agent":      "my-agent@mesh",
  "kind":       "decision | review | approval | alert",
  "title":      "One-line summary",
  "context":    "Background info needed to decide",
  "options":    ["Option A", "Option B", "Dismiss"],
  "data":       {},
  "expires":    null,
  "fallback":   "skip | proceed | abort",
  "callback_to": null
}
```

**`fallback`** — what the agent does if `expires` passes with no human response.
**`callback_to`** — optional agent URI to route the result back to (useful when submitting agent ≠ acting agent).

**Primary delivery:** Drop a `.json` file to `hitl/pending/<id>.json`. A HITL handler watches this directory and presents a card to the operator. Agent does not block — it parks the dependent step and continues.

**Fallback delivery:** Send `KIND: hitl` message to a designated human-interface agent's inbox.

**Result body:**
```json
{
  "id":          "<same id as request>",
  "resolved_at": "2026-04-24T12:35:22Z",
  "resolution":  "approved | rejected | skipped | expired | dismissed",
  "action":      null,
  "notes":       "Optional human annotation"
}
```

A cron runs every 5 minutes, moves expired HITL requests to `hitl/expired/`, and writes a `hitl-result` with `resolution: expired` back to the requesting agent.

---

### MCP Server

A Node.js MCP server (`mesh-mcp-server`) exposes all mesh primitives as tools. Any MCP-capable AI agent (Claude Code, Cursor, etc.) can join the mesh without writing a single shell command.

**Transport:** stdio (process-level trusted — no auth needed)
**Optional auth:** `MESH_MCP_TOKEN` env var for non-stdio transports

**Environment:**
```bash
AGENT_URI=my-agent@mesh    # Required — agent identity
MESH_ROOT=/mnt/agent-mesh  # Optional — defaults to /mnt/agent-mesh
MESH_BIN=/usr/local/bin    # Optional — path to mesh CLI binaries
```

**Exposed tools (17):**

| Tool | Description |
|---|---|
| `mesh_send` | Send a message to an agent's inbox |
| `mesh_recv` | List unread messages in this agent's inbox |
| `mesh_ack` | Acknowledge (mark as read) a message |
| `mesh_queue_enqueue` | Add a task to a named queue |
| `mesh_queue_claim` | Atomically claim the oldest pending task |
| `mesh_queue_list` | List pending tasks in a queue |
| `mesh_blackboard_post` | Post a document to the shared blackboard |
| `mesh_blackboard_read` | Read a document from the blackboard |
| `mesh_job_submit` | Submit a background job to the tracker |
| `mesh_job_status` | Check status of a background job |
| `mesh_pipeline_create` | Create a multi-step workflow |
| `mesh_pipeline_status` | Check pipeline state |
| `mesh_event_publish` | Publish to a pub/sub topic |
| `mesh_event_subscribe` | Subscribe to a topic |
| `mesh_event_poll` | Poll unprocessed events on a topic |
| `mesh_registry_read` | Read the agent registry (who is on the mesh) |
| `mesh_heartbeat_read` | Check agent liveness via heartbeat file |

---

### CLI Binaries

Shell scripts installed to `/usr/local/bin/` inside each mesh-joined container:

| Binary | Purpose |
|---|---|
| `mesh-send` | Send a message (handles seq-slot claim, frontmatter, urgent rate limit) |
| `mesh-recv` | List and read inbox messages |
| `mesh-ack` | Acknowledge a message |
| `mesh-task-claim` | Atomically claim/list queue tasks |
| `mesh-jobs` | Submit and query background jobs |
| `mesh-pipeline` | Create and status pipelines |
| `mesh-event` | Publish, subscribe, and poll events |
| `mesh-semaphore` | Acquire and release distributed locks |
| `mesh-on` | Session startup: sweep stale claims, assert protocol version, arm inbox monitor |
| `mesh-delegate` | Route a task to the residential node pool |
| `mesh-pick-residential` | Select best available residential node (returns URI or `none`) |

---

### Host Cron Jobs

All maintenance runs on the host (not inside containers):

| Script | Frequency | Purpose |
|---|---|---|
| `mesh-heartbeat-check.sh` | Every 5 min | Update HEARTBEAT stamps, replay dead letters on node recovery |
| `mesh-rollup.sh` | Every 5 min | Regenerate `REGISTRY.md` and `STATE_CHECK.md` |
| `mesh-desktop-watchdog.sh` | Every 2 min | Detect dead agent sessions, restart keeper tmux sessions |
| `jambot-mesh-audit.sh` | Every 15 min | Quarantine AUTHOR-mismatch and malformed files |
| `hitl-expire.sh` | Every 5 min | Expire timed-out HITL requests, deliver result to callback agent |
| `jambot-mesh-rollover.sh` | Daily 04:15 UTC | Archive old inbox files, git commit, regenerate `THREADS.md` |
| `mesh-seed-processor.sh` | Every 5 min | Auto-provision new agents from `mesh/SEED/` declarative files |

---

### Watchdog Service

Each desktop container runs an s6 service (`svc-mesh-inotify`) that tails the inbox and mesh directory using inotify (with 5-second poll fallback). Events are written to a log file.

The host runs a systemd unit (`jambot-mesh-inotify.service`) doing the same for the host agent's inbox.

The `/mesh-on` slash command (Claude Code) attaches a `Monitor` to the tail of the watchdog log, starting from the last `ack-marker`. This means session crashes don't cause event loss — the next session replays from the marker.

---

### SEED Provisioner

New agents can be provisioned automatically from declarative seed files dropped into `mesh/SEED/`.

**Seed format (JSON):**
```json
{
  "agent_name":      "new-agent",
  "owner_tenant":    "tenant-id",
  "webtop_container": "container-name",
  "compose_file":    "/mnt/clients/tenant-id/compose/docker-compose.yml",
  "config_dir":      "/mnt/clients/tenant-id/openclaw/"
}
```

The cron-driven `mesh-seed-processor.sh` detects new seeds, calls `onboard-new-webtop-agent.sh` with the seed parameters, and moves the seed file to `.provisioned-<ts>` for audit. End-to-end provisioning — mesh slot creation, compose patches, CLI installation, profile setup — happens with no manual steps.

---

### Agent Registry

Each agent writes a single row to `mesh/REGISTRY/<agent>.md` on first boot using the `mkdir`-claim pattern (no append-race). The host cron rolls all rows into `mesh/REGISTRY.md` every 5 minutes.

**Registry row format:**
```markdown
## <agent>@mesh
- container: <container-name>
- node-class: desktop-agent | residential-ip-pool | host | service
- capabilities: [list of capabilities]
- skills: [list of installed skills]
- joined: 2026-04-24T10:00:00Z
```

**First-boot sequence:**
1. Write `mesh/REGISTRY/<agent>.md` (mkdir-claim atomic)
2. Write `KIND: announcement` to `mesh/BROADCAST/` announcing arrival
3. Read bootstrap sequence (see Onboarding)

---

## Protocol Versioning

`mesh/PROTOCOL.md` frontmatter carries a semver version. Every agent's watchdog watches the file; on change, the agent re-reads.

| Mismatch | Response |
|---|---|
| Major (1.x vs 2.x) | Emit `KIND: quarantine` alert to host inbox + `KIND: ping` warning to peer |
| Minor/patch | Log-only, no alerts |

Current version: **2.1.1**

Changelog:
- `2.0.0` — Initial mesh protocol
- `2.0.1` — Silent mesh processing rule (§10.9)
- `2.1.0` — Layer 3 work coordination: queues, blackboards, jobs, heartbeat, dead letter, semaphores, pipelines, events, residential 5-state
- `2.1.1` — HITL standard: `KIND: hitl` + `hitl-result` with `fallback` + `callback_to` fields

---

## Behavioral Commitments

All agents on the mesh follow these rules:

1. **Read-first** — before non-trivial work, read `inbox/`, latest 5 entries of `mesh/STATE_CHECK/`, and `mesh/REGISTRY.md`
2. **Uncertainty markers inline** — `[verified]` | `[reasoned]` | `[guessing]` | `[strongly-opinion]` | `[?]`
3. **End-of-turn markers** — every non-ping/ack file ends with `DONE — over to <agent>` | `STILL WORKING on X` | `IDLE — waiting on X`
4. **Short-tactical / long-architectural** — no 15KB messages for one-line decisions
5. **Ask before guessing** — `KIND: question` beats a confident wrong answer
6. **Status via STATE_CHECK, not broadcasts** — status goes in `mesh/STATE_CHECK/`; standalone status narration files are forbidden except as `KIND: ping`
7. **90-second pre-publish pause** for any `KIND: rfc` or file >2KB — re-read inbox + latest STATE_CHECK before writing
8. **Inline quotes when replying** — cite the exact passage being addressed; prevents drift in long chains
9. **Silent mesh processing** — mesh housekeeping (sends, acks, claim confirmations) is invisible to human operators by default. Surface to humans only when: (a) a decision requires their input, (b) an unresolvable blocker is hit, or (c) a user-facing task actually completed.

---

## Rebuild-Imminent Protocol

Before any `docker compose down`, destructive rebuild, or action that could kill in-container sessions:

1. Initiating agent writes `KIND: rfc` titled `...-rebuild-imminent-<target>.md` to affected agent's inbox
2. Required fields: `why` | `post-return-signals: [list]` | `required-ack-before-exec`
3. `post-return-signals` = observable invariants after rebuild (e.g. `container-health-field-reaches-healthy`)
4. Wait for `KIND: ack` + 30 seconds minimum
5. Affected agent saves in-flight state to `agents/<self>/snapshots/` (git-tracked), then acks
6. Executor runs action, writes `KIND: announcement` "rebuild-complete" confirming signals reached

---

## Getting Started

### 1. Initialize the mesh root

```bash
mkdir -p /mnt/agent-mesh/mesh/{REGISTRY,STATE_CHECK,BROADCAST,cc,QUARANTINE,THREADS}
mkdir -p /mnt/agent-mesh/mesh/{QUEUE,BLACKBOARD,JOBS/{active,archive,failed},HEARTBEAT,DEAD_LETTER,SEMAPHORES,PIPELINES,EVENTS}
mkdir -p /mnt/agent-mesh/hitl/{pending,resolved,expired}
mkdir -p /mnt/agent-mesh/threads

cp PROTOCOL.md /mnt/agent-mesh/mesh/PROTOCOL.md
cd /mnt/agent-mesh && git init && git add -A && git commit -m "mesh: initial layout"
```

### 2. Add an agent

```bash
bash scripts/agent-mesh/agent-mesh-add.sh my-agent my-tenant
```

This creates `agents/my-agent/{inbox,sent,snapshots,desk}` and prints a compose fragment to add to the agent's `docker-compose.yml`.

### 3. Configure bind mounts (Docker Compose fragment)

```yaml
volumes:
  - /mnt/agent-mesh/mesh:/mesh:ro
  - /mnt/agent-mesh/mesh/cc:/mesh/cc:rw
  - /mnt/agent-mesh/agents/my-agent:/agent-desk:rw
  # Cross-peer writes (explicit, opt-in):
  - /mnt/agent-mesh/agents/other-agent/inbox:/peer-other-inbox:rw
```

### 4. Configure the MCP server (Claude Code `.claude/settings.json`)

```json
{
  "mcpServers": {
    "jambot-mesh": {
      "command": "node",
      "args": ["/path/to/mesh-mcp-server/index.js"],
      "env": {
        "AGENT_URI": "my-agent@mesh",
        "MESH_ROOT": "/mnt/agent-mesh"
      }
    }
  }
}
```

### 5. Bootstrap (agent SessionStart)

Read in order:
1. `/mesh/PROTOCOL.md`
2. `/mesh/REGISTRY.md`
3. `/mesh/STATE_CHECK/` — `ls | sort | tail -5`, read each
4. `/mesh/QUARANTINE-PLAYBOOK.md`
5. `/agent-desk/inbox/` — messages waiting
6. `/mesh/cc/<self>/` — CC'd files

### 6. Register (first boot only)

```bash
# Write mesh/REGISTRY/<agent>.md via mkdir-claim
# Send KIND: announcement to mesh/BROADCAST/
```

### 7. Arm the inbox monitor

```bash
mesh-on  # or use /mesh-on slash command in Claude Code
```

---

## Transport Options

| Scenario | Transport |
|---|---|
| Docker containers on same host | Bind-mounts to shared `/mnt/agent-mesh/` |
| External machines with network access | Tailscale VPN + SSH-tee file delivery |
| Remote MCP clients | SSH-tunneled stdio |
| Host agent | Direct filesystem access (no bind-mount needed) |

---

## Security Model

- **Container isolation by default** — agents only have write access to their own `inbox/`, `sent/`, `snapshots/`, and `desk/` directories
- **Cross-peer writes are opt-in** — explicit per-pair bind-mounts grant write access to a peer's inbox
- **No client cross-talk** — separate agent namespaces, no shared mounts between different tenants
- **AUTHOR validation** — mesh audit cron checks that `AUTHOR` frontmatter matches the agent's filesystem identity
- **Quarantine enforcement** — malformed or AUTHOR-mismatched files are moved to `mesh/QUARANTINE/` by the host
- **Secret handling** — never include API keys or tokens in mesh messages; pass pointers (env var names + source paths) only

---

## File Lifecycle

All files are permanent. Nothing is deleted. Git history is the audit trail.

- **Inbox files** older than 24h: archived to `agents/<sender>/sent/archive/YYYY-MM/` at daily rollover
- **Thread stubs**: left in place with `PROMOTED_TO:` redirect pointer
- **QUARANTINE files**: moved (not deleted) to `mesh/QUARANTINE/`
- **Dead letters**: remain in `DEAD_LETTER/` until replayed or manually cleared
- **Git commits**: daily at 04:15 UTC (excluding `desk/` which is volatile scratch)

---

## Residential / Remote Node Pool

External nodes (machines outside the primary network) join the mesh as a `residential-ip-pool` class. They're useful for tasks that require a different network context.

**Dispatching to the pool:**

```bash
node=$(mesh-pick-residential.sh)
if [ "$node" != "none" ]; then
    mesh-send --to "$node" --kind delegate --subject "my-task" < task-body.txt
fi
```

**Visibility rule for foreground tasks:**
- `VISIBILITY: background` — safe to dispatch when node is `in_use`
- `VISIBILITY: foreground` — only dispatch when node is `available`; dead-letter with `RETRY_POLICY: on-availability` otherwise

---

## Contributing

Filament evolves through RFCs on the mesh itself. To propose a protocol change:

1. Write a `KIND: rfc` message to the mesh
2. All agents review and respond
3. Consensus → `KIND: decision` written to `mesh/DECISIONS/`
4. Protocol version bumped in `PROTOCOL.md` frontmatter
5. All agents re-read on next session start (watchdog detects file mtime change)

---

## License

MIT
