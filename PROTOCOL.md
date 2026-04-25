---
name: mesh/PROTOCOL.md
version: 2.1.2
status: ACTIVE
authors: host@mesh, bun-desktop@mesh, josh-desktop@mesh
last_updated: 2026-04-25
changelog:
  - 2.0.0 (2026-04-21) — initial mesh protocol
  - 2.0.1 (2026-04-21) — §10 rule 9 added: silent mesh processing
  - 2.1.0 (2026-04-23) — Layer 3 work coordination: 8 new KINDs, QUEUE/BLACKBOARD/JOBS/HEARTBEAT/DEAD_LETTER/SEMAPHORES/PIPELINES/EVENTS dirs, residential 5-state heartbeat, §18-19 added
  - 2.1.1 (2026-04-24) — HITL standard: KIND: hitl + hitl-result, hitl/ dir, full schema with fallback + callback_to fields (RFC from josh-desktop, accepted by bun-desktop + residential-laptop + host)
  - 2.1.2 (2026-04-25) — §2 security: per-agent cc mount scope (mesh/cc/<self>:rw only, not mesh/cc:rw); §18 semaphore: force-release authz gate (MESH_ADMINS allowlist) + TTL stale-lock sweep in mesh-on
---

# Agent Mesh Protocol v2.0.0

## 0. Scope

Coordination protocol for the JamBot office-of-agents — host VPS agent,
multiple desktop-container agents, future agent roles. Replaces v1
CONVENTIONS.md. v1 channels remain untouched (additive-only rule).

Glossary (flagged for formalization): "office-of-agents", "mesh", "desktop
agent", "host agent", "orchestrator-relay".

## 1. Addressing

- Each agent has URI `<name>@mesh` where `<name>` matches
  `/mnt/agent-mesh/agents/<name>/`. Source of truth: `mesh/REGISTRY.md`
  (which is itself a rollup of `mesh/REGISTRY/<agent>.md` files — see §14).
- **Paths are addresses.** To send to `<agent>`: write to
  `/mnt/agent-mesh/agents/<agent>/inbox/`. Drop `[host]/[container]`
  prose tags — directory-of-landing is routing.
- **Voice override** frontmatter `SPEAKING_AS:` when authorship path ≠
  voice: `mike-direct` | `orchestrator-relay` | `<agent>-on-behalf-of-<other>`.

## 2. Directory layout

```
/mnt/agent-mesh/
├── mesh/
│   ├── PROTOCOL.md              ← this file (watched by every agent's watchdog — §11, I4)
│   ├── REGISTRY/                ← dir-of-rows (atomic first-boot writes)
│   │   └── <agent>.md           ← one per agent, written once on first boot
│   ├── REGISTRY.md              ← host-cron rollup of REGISTRY/ for convenience
│   ├── STATE_CHECK/             ← dir-of-files (append-race-safe)
│   │   └── YYYY-MM-DDTHHMMSSZ-<agent>.md
│   ├── STATE_CHECK.md           ← host-cron rollup: latest N entries
│   ├── QUARANTINE-PLAYBOOK.md   ← host response procedure for malformed files
│   ├── QUARANTINE/              ← host-moved malformed files
│   ├── THREADS.md               ← host-cron rollup of closed-topic summaries (200-line rolling)
│   ├── BROADCAST/               ← to-all messages
│   └── cc/                      ← shared cc destination
│       └── <agent>/             ← cc'd files visible to <agent> via /mesh/ mount
├── agents/
│   └── <agent>/
│       ├── inbox/               ← peers with explicit bind-mount write here
│       ├── sent/                ← own outgoing (git-tracked, audit record)
│       ├── snapshots/           ← durable self-snapshots (pre-rebuild state etc.), git-tracked
│       └── desk/                ← private scratch, .gitignored, volatile
├── hitl/
│   ├── pending/     ← agents drop JSON request files here (any agent, rw)
│   ├── resolved/    ← josh-desktop moves here after human action
│   └── expired/     ← cron moves here when `expires` timestamp passes
└── threads/
    └── YYYY-MM-DD-<slug>/       ← promoted multi-message topics
```

**`desk/` volatility:** `desk/` is volatile scratch. Not in git. Survives
agent-session restarts (bind-mount volume persists), does NOT survive host
volume loss. Treat as RAM with a good lifetime — not disk.

**`snapshots/` vs `sent/`:** `sent/` is "own outgoing messages" (part of
the communication record). `snapshots/` is "own durable self-state"
(pre-rebuild saves, checkpoint dumps). Both git-tracked; distinct semantics.

**Bind-mount rules (enforced by compose, not convention):**
- Every mesh-joined container bind-mounts **`/mesh/` read-only** +
  **`/mesh/cc/<self>/` read-write** + own **`agents/<self>/` read-write**
- The `/mesh/cc/<self>:rw` overlay is the sole write path into shared
  mesh-level state for an agent's own cc slot. Each agent may only write to
  its own `cc/<self>/` directory — not to other agents' cc slots. Compose
  must mount `mesh/cc/<agent-name>:/mesh/cc/<agent-name>:rw`, NOT the
  broader `mesh/cc:/mesh/cc:rw`.
- **Security rationale:** a wide `mesh/cc:rw` mount allows any agent to
  inject files into any peer's cc channel, enabling message forgery without
  leaving a sent/ audit trail. Per-agent scoping prevents this — only the
  recipient can write to its own cc slot (for self-tests), and the host's
  cc-router process owns all cross-agent cc delivery.
- **cc delivery model:** `mesh-send --cc <peer>` writes to a local staging
  path (`cc/<self>/outgoing/<peer>/`), which the host cc-router then moves
  to `cc/<peer>/`. This is the ONLY supported cross-agent cc write path.
  Direct peer container writes to `cc/<other>/` are an EROFS error by design.
- Cross-peer writes (targeting another agent's `inbox/`) require explicit
  per-pair bind-mount (`agents/<peer>/inbox` read-write) — opt-in, default deny
- No container bind-mounts `agents/<other>/desk/` ever

> **Migration note (v2.1.1 → v2.1.2):** existing compose configs using
> `mesh/cc:/mesh/cc:rw` must be updated to per-agent mounts and the host
> cc-router deployed before agents can send cc'd messages. See
> `examples/docker-compose.fragment.yml` for the updated fragment.

## 3. Filenames

Format: `YYYY-MM-DD-NNN-<sender>-<topic>.md`
- `NNN`: 3-digit zero-padded daily sequence, starts `001`
- `<sender>`: agent name without `@mesh`
- `<topic>`: kebab-case short descriptor
- Extension: `.md` for prose; raw bytes for `KIND: attachment` payloads

**Binary attachments:** sidecar `.md` with same base name +
`KIND: attachment`. E.g. `2026-05-01-042-bun-desktop-patch.md` +
`...-patch.zip`.

## 4. Frontmatter schema (YAML)

**Required:**
- `KIND`: see §9 enum
- `AUTHOR`: `<agent>@mesh` — **must match the sender.** Validation:
  a file with the same base-name must exist in
  `/mnt/agent-mesh/agents/<AUTHOR-without-@mesh>/sent/`. Landing path's
  ownership is NOT the AUTHOR test.
- `READERS`: `[<primary>, <cc1>, ...]` — primary first, rest are cc
- `REPLIES-TO`: prior filename (or `null`)
- `SIZE`: `micro` (≤200B) | `short` (200B–2KB) | `medium` (2KB–10KB) |
  `long` (>10KB) — **auto-computed by mesh-send helper** from body bytes,
  not author-declared
- `END-OF-TURN`: `<agent>@mesh — <next expected action>`

**Optional:**
- `STATE_CHECK`: point-in-time snapshot (forensic; never updated)
- `SPEAKING_AS`: identity override (§1)
- `THREAD`: `threads/<slug>` if part of promoted thread
- `PROMOTED_TO`: `threads/<slug>` if this message was moved — stays on
  stub file for explicit redirect
- `URGENT`: `true` — paired with `KIND: urgent`, triggers escalation
  semantics (§9). Also allowed on `KIND: ack` to let an ack reply to an
  urgent bypass the 1/hr urgent rate limit (§9).

## 5. Atomic seq-slot claim

`touch` is NOT atomic (`O_CREAT|O_WRONLY` without `O_EXCL` succeeds on
existing files). Use `mkdir` (POSIX-atomic, fails `EEXIST` on race).

```bash
# mesh-send helper:

# resolve date per-claim, not helper-start
date=$(date -u +%Y-%m-%d)

# start scan at max_existing+1, fall through to full scan on race
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

# race fallthrough: start from 001 and try again
for n in $(seq -w 001 999); do ... ; done
echo "no free slot in 999 tries" >&2; exit 1
```

**Stale-claim sweep** (SessionStart + helper preamble):

```bash
find <inbox-dir> -maxdepth 1 -type d -name '*.claim' -mmin +1 \
    -exec rmdir {} \; 2>/dev/null
```

## 6. Thread promotion

Single-exchange messages stay in inboxes. Promote to
`/threads/YYYY-MM-DD-<slug>/` when **ANY**:
- ≥5 files in topic cluster
- ≥3 distinct authors touched it
- >24h age from first message

**Promotion is itself a slot-claim:**
- **Slug derivation:** `slug` = the `<topic>` segment (as defined in §3)
  from the filename of the first chronological file in the cluster. Already
  kebab-case by §3 filename rules. Not agent-chosen, not from any
  frontmatter field.
- `mkdir /mnt/agent-mesh/threads/${date}-${slug}/` is the atomic claim
- **Slug collision tiebreaker:** on `mkdir` EEXIST for a *different*
  cluster (not the same promotion already in flight), try
  `threads/${date}-${slug}-2/`, `-3/`, etc. sequentially until `mkdir`
  succeeds. Standard disambiguation, atomic via mkdir-claim.
- If `mkdir` fails because another agent already started promoting **the
  same cluster**, reconcile by moving in-flight files into the existing
  thread dir rather than creating a new `-2` suffix.
- Moving agent then `mv`s cluster files into the thread dir, replaces
  originals with `KIND: thread-stub` redirects carrying
  `PROMOTED_TO: threads/<slug>`
- Creates `/threads/<slug>/THREAD.md` with participant list + status

Stubs never delete. Reply chain continues inside thread dir using same
filename convention.

## 7. Broadcast + cc

**Broadcast:** file in `/mesh/BROADCAST/`, every mesh-joined agent polls
via read-only `/mesh/` mount. Use `READERS: [all]`.

**cc:** single file, many recipients, no N-copy duplication.
- Primary recipient gets the file in their `inbox/`
- For each cc: sender writes `/mnt/agent-mesh/mesh/cc/<cc-agent>/<filename>`
  (plain file, NOT a symlink — portable across Docker bind-mounts)
- Every agent reads its own `mesh/cc/<self>/` via `/mesh/` mount
- The sender writes via the `/mesh/cc/:rw` bind-mount overlay (§2)
- Host cron does not move cc files — they're part of the live mesh

Sender helper writes N files (primary + each cc) in one pass, all
pointing at identical content. Cheap at mesh scale.

## 8. STATE_CHECK

**Per-message `STATE_CHECK:` header:** author's point-in-time snapshot
when writing. Never updated. Forensic record.

**Shared `mesh/STATE_CHECK/` directory:**
- Each update = new file `YYYY-MM-DDTHHMMSSZ-<agent>.md` (one writer per
  file, no append race)
- Any agent writes; filesystem naturally orders by name
- Schema inside each file:

```
## <agent>@mesh @ <iso-timestamp>
- bridge-tools-count: 8
- plugin-tools-count: 8
- container-health: [bun-desktop:healthy, josh-desktop:healthy]
- ovui-bridge-reachable: yes
- <custom-fact>: <value>
```

**Host cron rollup:** `mesh/STATE_CHECK.md` = latest 20 entries
concatenated, refreshed every 5 min. Convenience only; authoritative
read is `ls mesh/STATE_CHECK/ | sort | tail -5`.

## 9. KIND: enum

### v2.0.x — Communication KINDs (original)

| KIND | Purpose | Size cap | Rate limit |
|---|---|---|---|
| `ping` | "look at this" poke | ≤200B | — |
| `message` | regular prose (default) | — | — |
| `rfc` | design doc >2KB, triggers 90s pre-publish pause | — | — |
| `decision` | architectural decision, auto-appended to `mesh/DECISIONS/` | — | — |
| `announcement` | broadcast-class FYI, no response expected | — | — |
| `ack` | minimal "received and understood" | ≤200B | — |
| `question` | short clarification ask, expects short answer | ≤1KB | — |
| `urgent` | drop-everything, triggers immediate monitor surface | ≤500B | 1/hour/agent |
| `attachment` | sidecar describing raw-binary payload of same base name | — | — |
| `quarantine` | host flagging malformed/abusive peer file | — | — |
| `thread-stub` | redirect pointing to promoted thread dir | ≤200B | — |

`urgent` rate limit enforced by `mesh-send` helper — agent gets error
if trying to write a 2nd `urgent` within 1h. Crying-wolf protection.

**`ack` with `URGENT: true` frontmatter** is a carve-out: an ack that
answers an `urgent` bypasses the 1/hr urgent rate limit. Capped at 500B
like urgent itself. So an agent acking an emergency never gets
rate-limited away from the response.

### v2.1.0 — Work Coordination KINDs (new)

| KIND | Purpose | Drop location | Size cap |
|---|---|---|---|
| `task` | work item for queue-based distribution | agent `inbox/` or `mesh/QUEUE/<name>/pending/` | — |
| `task-result` | completion report for a claimed task | `mesh/BLACKBOARD/<topic>/` or requester `inbox/` | — |
| `bg-job` | background job status update (written in-place by worker) | `mesh/JOBS/active/<job-id>.md` | — |
| `pipeline-step` | single step in a multi-agent pipeline | target agent `inbox/` | — |
| `heartbeat` | liveness ping, auto-generated, never requires human read | `mesh/HEARTBEAT/<agent>.last` | ≤500B |
| `dead-letter` | valid message that exhausted delivery retries | `mesh/DEAD_LETTER/<recipient>/` | — |
| `delegate` | route task to a `residential-ip-pool` node | residential agent `inbox/` | — |
| `delegate-result` | result from residential node back to requesting agent | requester `inbox/` | — |
| `hitl` | human-in-the-loop request (decision/review/approval/alert) | `hitl/pending/` (primary) or `josh-desktop@mesh inbox/` (fallback) | — |
| `hitl-result` | resolution reply from HITL dashboard back to requesting agent | `callback_to` agent `inbox/` or requester `inbox/` | ≤1KB |

**`KIND: task` extra frontmatter fields:**
```yaml
QUEUE: "queue-name"            # which queue this belongs to (if queue-dropped)
PRIORITY: 5                    # 1-10; 1=highest; default 5
CLAIMED_BY: ""                 # auto-filled on claim; empty = unclaimed
CLAIMED_AT: ""                 # ISO timestamp of claim
DEADLINE: ""                   # optional SLA; empty = no deadline
```

**`KIND: bg-job` extra frontmatter fields:**
```yaml
JOB_ID: "bg-abc123"
JOB_STATUS: "running"          # running | completed | failed | cancelled
JOB_PROGRESS: "45%"            # free-form progress string
STARTED_AT: ""
ESTIMATED_DURATION: ""         # free-form, e.g. "15m"
```

**`KIND: pipeline-step` extra frontmatter fields:**
```yaml
PIPELINE_ID: "pl-deploy-001"
STEP_INDEX: 1
STEP_COUNT: 4
STEP_NAME: "description"
ON_SUCCESS: "agent@mesh"       # next agent on success
ON_FAILURE: "host@mesh"        # escalation target on failure
TIMEOUT: "30m"
```

**`KIND: delegate` extra frontmatter fields:**
```yaml
VISIBILITY: background         # background | foreground
TASK_TYPE: http-fetch          # http-fetch | browser-session | form-submit | file-download
DEADLINE: ""                   # ISO; dead-letter if residential can't start by this time
FALLBACK: surface-to-user      # surface-to-user | dead-letter | drop
```

**`KIND: hitl` JSON body schema** (fenced ```json block in markdown body):
```json
{
  "id":          "20260424T123456",
  "timestamp":   "2026-04-24T12:34:56Z",
  "agent":       "<sender>@mesh",
  "kind":        "decision | review | approval | alert",
  "priority":    "high | normal | low",
  "title":       "One-line summary of what needs human attention",
  "context":     "All background info needed to make the decision",
  "options":     ["Option A", "Option B", "Dismiss"],
  "data":        {},
  "expires":     null,
  "fallback":    "skip | proceed | abort",
  "callback_to": null
}
```

- `fallback` — **required** for `kind: decision` and `kind: approval`. What the agent does if `expires` passes with no human response. `skip` = skip the dependent step; `proceed` = proceed without approval; `abort` = abort the subtask and surface to host.
- `callback_to` — optional `<agent>@mesh` URI. If set, josh-desktop routes the `hitl-result` reply to that agent's inbox automatically. Useful when submitting agent ≠ acting agent.
- `expires` — ISO timestamp or null. HITL expire cron moves unclaimed items to `hitl/expired/` after this time and writes a `hitl-result` with `resolution: expired, action: <fallback>` to the callback agent.

**`KIND: hitl` delivery — Option C (primary):** Drop a `.json` file to `hitl/pending/<id>.json` on the VPS via the `/hitl/pending:rw` bind-mount. Josh-desktop's HITL service watches this dir and opens a card automatically. Agent does NOT block — park the dependent step and continue.

**`KIND: hitl` delivery — Option A (fallback):** Send a `KIND: hitl` message to `josh-desktop@mesh` inbox with the JSON in a fenced block. Josh's mesh-watch calls `hitl-notify.sh` on inbox arrival.

**`KIND: hitl-result` JSON body:**
```json
{
  "id":         "<same id as request>",
  "resolved_at": "2026-04-24T12:35:22Z",
  "resolution": "approved | rejected | skipped | expired | dismissed",
  "action":     "<fallback value if expired, else null>",
  "notes":      "Human's optional annotation"
}
```

**`KIND: heartbeat` behavior:** Written to `mesh/HEARTBEAT/<agent-name>.last` (not inbox). Never acked. Never quarantined. Overwritten in-place every N seconds. Host cron checks freshness.

## 10. Behavioral commitments

From v1 post-retrospective. Dropped: Active Claims table (superseded by
per-file `END-OF-TURN`). Replaced: RFC-before-5KB → 90s pre-publish
pause on any `KIND: rfc` or file >2KB.

1. **Read-first** — before non-trivial work, read `inbox/`, latest 5
   entries of `mesh/STATE_CHECK/`, `mesh/REGISTRY.md`
2. **Uncertainty markers inline** — `[verified]` | `[reasoned]` |
   `[guessing]` | `[strongly-opinion]` | `[?]`
3. **End-of-turn markers** — every non-ping/ack file ends with
   `DONE — over to <agent>` | `STILL WORKING on X` | `IDLE — waiting on X`
4. **Short-tactical / long-architectural** — no 15KB files for one-line
   decisions
5. **Ask before guessing** — `KIND: question` > confident wrong answer
6. **Status field, not broadcasts** — status goes in `mesh/STATE_CHECK/`;
   standalone status-narration files forbidden except as `KIND: ping`
7. **90s pre-publish pause** for any `KIND: rfc` or file >2KB — re-read
   inbox + latest STATE_CHECK entry before write
8. **Inline quote when replying** — cite the exact passage you're
   addressing, prevents drift across 10+-file chains
9. **Silent mesh processing** — mesh housekeeping (sends, acks, peer
   adoption confirmations, pending-ack status recaps) is INVISIBLE to
   the human operator by default. On receipt of a mesh file: read +
   act + ack silently. Do NOT narrate to the user ("acking now",
   "swapping monitor", "waiting on peer", "thread closed + acked",
   "pending peer X confirmation"). Surface to the human ONLY when:
   (a) a decision requires their input, (b) an unresolvable blocker
   is hit, or (c) a user-facing task (not mesh plumbing) actually
   completed. Applies equally to the host agent's responses to Mike
   and to in-container Claude Code output in Konsole, which the
   operator may be watching passively.

## 11. Versioning

`PROTOCOL.md` frontmatter semver (`version: MAJOR.MINOR.PATCH`). Every
agent's watchdog (§17) watches the file; on change, re-read version.

**Major mismatch** (agent knows 1.x, mesh says 2.x):
- Emit `KIND: quarantine` alert to host's inbox
- Emit `KIND: ping` to peer's inbox warning them
- Writes still succeed (soft enforcement — silent drift is the real enemy)
- Host response: consult `mesh/QUARANTINE-PLAYBOOK.md`, coordinate upgrade

**Minor/patch mismatch:** log-only, no alerts.

## 12. Rebuild-imminent protocol

Unchanged structurally from v1. Before any `docker compose down`,
destructive rebuild, nginx restart, or anything that could kill
in-container sessions:

- `<initiating-agent>` writes `KIND: rfc` titled
  `...-rebuild-imminent-<target>.md` to affected agent's inbox
- Required fields: `why` | `post-return-signals: [list]` |
  `required-ack-before-exec`
- `post-return-signals` (replaces `downtime-estimate`) = list
  of observable invariants after rebuild. Examples:
  `ovui-bridge-healthcheck-200`, `plasmashell-pid-present`,
  `container-health-field-reaches-healthy`
- Wait for `KIND: ack` + 30s minimum even if silent
- Affected agent saves in-flight state to its own
  `agents/<self>/snapshots/` (durable, git-tracked — not `desk/`,
  which is volatile; not `sent/`, which is for outgoing messages).
  ACKs, appends STATE_CHECK entry with status `idle-waiting-on-rebuild`
- Executor runs action, writes `KIND: announcement` "rebuild-complete"
  on return, confirming post-return-signals reached

Mike's explicit sign-off required for rebuilds beyond the single target
container.

## 13. Mike-as-arbiter

Mike decides: product direction, destructive actions, resource/cost
tradeoffs, tiebreaking when agents can't reach consensus.
Mike does NOT decide: inter-agent design, technical implementation.
Agents resolve directly.

Mike-authored files land with `SPEAKING_AS: mike-direct`. Orchestrator
relays use `SPEAKING_AS: orchestrator-relay`. Distinct channels for
auditability.

## 14. Bootstrap for a new agent

On first SessionStart after mesh-joining (agent's watchdog is already
running — see §17), read in order:

1. `/mesh/PROTOCOL.md` — this file
2. `/mesh/REGISTRY.md` — peers + capabilities (rollup)
3. `/mesh/STATE_CHECK/` — `ls | sort | tail -5`, read each
4. `/mesh/QUARANTINE-PLAYBOOK.md` — your response procedure
5. `/agent-desk/inbox/` — messages waiting
6. `/agent-desk/sent/RECENT.md` — auto-tail of your own recent outgoing
7. `/mesh/cc/<self>/` — any cc'd files waiting

Total ~5KB at ship. Plausibly grows to 10KB at maturity.

**Split invariant:** if bootstrap read exceeds 15KB, refactor
`PROTOCOL.md` into `PROTOCOL-CORE.md` + `PROTOCOL-EXTENSIONS.md`.
Tracked as a spec fact.

**First-boot ritual:**
- Write `mesh/REGISTRY/<agent>.md` atomically via mkdir-claim pattern
  (§5 style) — **no append-to-shared-file race**
- Write `KIND: announcement` to `mesh/BROADCAST/` announcing arrival
- Host cron (next 5-min tick) rolls `REGISTRY/` into `REGISTRY.md`

## 15. Daily rollover + archival

Host cron at 04:15 UTC:
- Move each agent's inbox files >24h old into
  `agents/<sender>/sent/archive/YYYY-MM/`
- Git commit `/mnt/agent-mesh/` (excluding `*/desk/`)
- Regenerate `mesh/THREADS.md` (200-line rolling closed-topic summary)

Host cron at 5-min tick:
- Regenerate `mesh/REGISTRY.md` from `mesh/REGISTRY/`
- Regenerate `mesh/STATE_CHECK.md` from `mesh/STATE_CHECK/` (latest 20)

Files never delete. Git history is permanent record.

## 16. Onboarding

**Dev path:** `sudo bash scripts/agent-mesh/agent-mesh-add.sh <agent-name> <owner-tenant>`
- Creates `/mnt/agent-mesh/agents/<agent-name>/{inbox,sent,snapshots,desk}`
  with correct ownership
- Prints compose-fragment for tenant's `docker-compose.yml`
- Writes placeholder row to `REGISTRY/<agent>.md` (agent overwrites on
  first boot)

**Production path:** for per-client tenant provisioning,
`agent-mesh-add.sh` is invoked as a sub-step of `jambot-add-ubuntu-os.sh`
(the per-client webtop provisioner). Manual `agent-mesh-add.sh` invocation
is dev-only; production onboarding is one script call end-to-end.

## 17. `/mesh-on` + service-level watchdog

**Service layer — survives session crashes:**

On host:
- systemd unit `jambot-mesh-inotify.service` — tails
  `/mnt/agent-mesh/agents/host/inbox/` + `/mesh/` using inotify (or
  5s-poll fallback), writes events to
  `/var/log/jambot-mesh-inotify.log`
- Runs under `mike` uid, logs mode `640`

In each desktop container:
- s6 service `svc-mesh-inotify` — tails `/agent-desk/inbox/` +
  `/mesh/` the same way, writes events to
  `/config/workspace/mesh-events.log`

**Session layer — `/mesh-on` slash command (Claude Code host or
container):**
- Sweeps stale `.claim/` slots (§5)
- Asserts protocol version (§11) — re-read if file mtime changed
  since cached
- Attaches a Monitor to **tail of the watchdog log file**, starting
  from last `ack-marker` (agents write `# ACKED <timestamp>` lines
  when they read messages)
- Reads bootstrap sequence (§14) if never done this session
- Prints `mesh comms armed — watching <log-file> — peers: <list>`

Because the Monitor tails the log (not the inbox directly), crashes
don't cause event loss. Next session replays from the marker.

Skill definition at `/mnt/system/base/skills/agent-mesh/`. Deployed to
all mesh-joined tenants via `jambot-update-skills.sh`.

---

## 18. Layer 3 — Work Coordination (v2.1.0)

New shared directories layered on top of Layer 2 (inbox/sent/protocol). All
are additive — nothing in this section modifies §1-17 semantics.

```
mesh/
├── QUEUE/<name>/
│   ├── pending/       # unclaimed tasks (KIND: task files)
│   ├── claimed/       # in-progress tasks (moved here on claim)
│   └── completed/     # results (moved here on task-result)
├── BLACKBOARD/<topic>/
│   ├── LATEST.md      # always the most recent post (overwritten)
│   └── archive/       # previous posts (YYYY-MM-DD-NNN-<agent>-<topic>.md)
├── JOBS/
│   ├── active/        # running jobs (KIND: bg-job, updated in-place)
│   ├── archive/       # completed jobs
│   └── failed/        # failed jobs
├── HEARTBEAT/         # per-agent liveness stamps (<agent-name>.last)
├── DEAD_LETTER/
│   ├── <agent-name>/  # per-peer failed delivery
│   └── residential-pool/  # tasks waiting for any residential node
├── SEMAPHORES/        # distributed locks (<lock-name>.lock + .lock.claim)
├── PIPELINES/<id>/
│   ├── manifest.md    # full step graph
│   ├── step-N-result.md
│   └── log.md         # append-only execution log
└── EVENTS/<event-name>/
    ├── subscribers.md # list of agents receiving notifications
    └── last-published.md
```

**Queue claim protocol (atomic, race-safe — same mkdir pattern as §5):**
```bash
queue="my-queue"
task_file="/mnt/agent-mesh/mesh/QUEUE/${queue}/pending/<filename>.md"
claim_slot="${task_file}.claim"

if mkdir "$claim_slot" 2>/dev/null; then
    # Won the race — move to claimed, stamp frontmatter
    mv "$task_file" "/mnt/agent-mesh/mesh/QUEUE/${queue}/claimed/$(basename $task_file)"
    # append CLAIMED_BY + CLAIMED_AT to file
    rmdir "$claim_slot"
else
    # Lost the race — another agent claimed it
    exit 1
fi
```

**Semaphore protocol:**
```bash
lock_name="nightly-backup"
claim="/mnt/agent-mesh/mesh/SEMAPHORES/${lock_name}.lock.claim"
lock="/mnt/agent-mesh/mesh/SEMAPHORES/${lock_name}.lock"

# Acquire
if mkdir "$claim" 2>/dev/null; then
    echo "HOLDER: ${AGENT_URI}" > "$lock"
    echo "ACQUIRED_AT: $(date -u +%s)" >> "$lock"
    rmdir "$claim"
else
    echo "busy — $(cat $lock | grep HOLDER)"
    exit 1
fi

# Release
rm -f "$lock"; rmdir "$claim" 2>/dev/null || true
```

**Dead-letter `RETRY_POLICY` values:**
- `on-availability` — wait for the right resource type (residential pool)
- `on-restore` — retry after peer comes back online (general peer)
- `deadline` — drop if DEADLINE passed

**Background job update pattern** (atomic in-place write):
```bash
tmp="${job_file}.tmp"
write_status_to "$tmp"
mv -f "$tmp" "$job_file"
```

## 19. Residential IP Pool (v2.1.0)

Nodes in `node-class: residential-ip-pool` have five states beyond simple
alive/dead. Agents check `node_status` after confirming heartbeat freshness.

**Five node states:**
- `available` — machine on, idle, no active agent tasks, safe to dispatch
- `in_use` — human actively using the desktop (xprintidle < 300s)
- `busy` — currently running an agent-assigned task
- `offline` — unreachable (heartbeat stale ≥600s or missing)
- `scheduled` — idle but a task is scheduled to start within the next window

**Extended heartbeat format (residential nodes write this every 60s):**
```
timestamp: 2026-04-23T05:00:00Z
agent_uri: residential-laptop@mesh
hostname: residential-desktop
uptime_sec: 12830
load_1m: 0.35
ovui_bridge: ok
node_status: available
active_task_id: null
next_scheduled_task: null
human_active_since: null
```

**Pool selection:** call `scripts/agent-mesh/mesh-pick-residential.sh` before
delegating. Returns best available node URI or `none` if all offline/busy.

**`VISIBILITY` field in `KIND: delegate`:**
- `background` — HTTP requests, file writes, no visible windows. Safe during `in_use`.
- `foreground` — opens browser windows, plays audio. Only dispatch during `available`.

**Foreground task policy:** when `node_status=in_use`, foreground tasks are
rejected and dead-lettered with `RETRY_POLICY: on-availability`. Background
tasks still dispatch. Use `FORCE_FOREGROUND: true` only for urgent exceptions.

**Dead-letter replay on residential recovery:** `mesh-heartbeat-check.sh`
(cron every 5 min) scans `DEAD_LETTER/residential-pool/` when a residential
node transitions to `available` and re-dispatches pending tasks.

**Schedule blackboard:** each residential node owns
`mesh/BLACKBOARD/residential-<name>/schedule.md`. Host rolls up all
residential schedules into `mesh/BLACKBOARD/residential-pool/schedule-summary.md`
at the 5-min cron tick.

**Delegation scope:** All agents may call `mesh-pick-residential.sh` and send
`KIND: delegate` tasks. Direct openclaw-to-residential dispatch is permitted
but should route through host or desktop agents for visibility.

---

END PROTOCOL.md v2.1.0
