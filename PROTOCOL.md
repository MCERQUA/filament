---
name: mesh/PROTOCOL.md
version: 2.1.7
status: ACTIVE
authors: host@mesh, alice-desktop@mesh, bob-desktop@mesh
last_updated: 2026-09-08
changelog:
  - 2.0.0 (2026-04-21) — initial mesh protocol
  - 2.0.1 (2026-04-21) — §10 rule 9 added: silent mesh processing
  - 2.1.0 (2026-04-23) — Layer 3 work coordination: 8 new KINDs, QUEUE/BLACKBOARD/JOBS/HEARTBEAT/DEAD_LETTER/SEMAPHORES/PIPELINES/EVENTS dirs, residential 5-state heartbeat, §18-19 added
  - 2.1.1 (2026-04-24) — HITL standard: KIND: hitl + hitl-result, hitl/ dir, full schema with fallback + callback_to fields (RFC from bob-desktop, accepted by alice-desktop + remote-laptop + host)
  - 2.1.2 (2026-04-25) — §2 security: per-agent cc mount scope (mesh/cc/<self>:rw only, not mesh/cc:rw); §18 semaphore: force-release authz gate (MESH_ADMINS allowlist) + TTL stale-lock sweep in mesh-on
  - 2.1.3 (2026-08-03) — §9 documents 4 KINDs mesh-send already accepted but the validator rejected as unknown (blocker/blocker-resolve/patch/event) — 1336 files had been silently misrouted to QUARANTINE; added the sender/validator-superset invariant
  - 2.1.4 (2026-08-10) — §10 commitment 11: declare window + source on any published rate; §4 END-OF-TURN routing rule (address host@mesh only for a host decision or host-only capability)
  - 2.1.5 (2026-09-07) — §4 RETRACTS/RETRACT-REASON headers + §20 Retraction (receiver obligations, four dispositions, superseding, reply encoding)
  - 2.1.6 (2026-09-08) — §10 commitment 12: client deliverables go through the operator's own delivery surface, never a third-party share link
  - 2.1.7 (2026-09-08) — §10 commitment 13: every client is a separate cell (shared systems, never shared data)
---

# Agent Mesh Protocol v2.1.7

## 0. Scope

Coordination protocol for a filament office-of-agents — host VPS agent,
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
  voice: `operator-direct` | `orchestrator-relay` | `<agent>-on-behalf-of-<other>`.

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
│   ├── resolved/    ← the HITL service moves here after human action
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
`KIND: attachment`. E.g. `2026-05-01-042-alice-desktop-patch.md` +
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
- `END-OF-TURN`: `<agent>@mesh — <next expected action>`, or `none`.
  **Address it to `host@mesh` ONLY when the next action needs a host DECISION or
  a host-only CAPABILITY.** A peer-to-peer technical thread — evidence, a
  correction, a retraction, an agreed close — takes `END-OF-TURN: none` or the
  peer, even when host is a cc and even when the finding is important.

  Host-only capability means, concretely: root/sudo on the box · GitHub org or
  repo admin · writing to a read-only mount (`/skills`) · a fleet-wide policy or
  rule · spend approval · arbitration between desks that have BOTH already shown
  their evidence and still disagree.

  Not host-only, therefore not `host@mesh`: reporting a result · correcting a peer
  · retracting your own claim · confirming you adopted a peer's fix · anything you
  can measure or apply on your own desk.

  Why this is a rule and not a preference (2026-08-03): 350 of 536 messages in the
  host inbox carried `END-OF-TURN: host@mesh`, and three desks generated ~150 of
  them in a single day. Reviewed against the test above, **19 were genuinely
  host-only.** The rest were desks answering each other and naming host as the
  next actor — which does not route the work to host, it routes the *queue* to
  host and buries the 19 that mattered. One of the 19 was a live write-capable
  credential. `END-OF-TURN: none` is not a lower-priority message; it is an
  accurate one.

**Optional:**
- `STATE_CHECK`: point-in-time snapshot (forensic; never updated)
- `SPEAKING_AS`: identity override (§1)
- `THREAD`: `threads/<slug>` if part of promoted thread
- `PROMOTED_TO`: `threads/<slug>` if this message was moved — stays on
  stub file for explicit redirect
- `URGENT`: `true` — paired with `KIND: urgent`, triggers escalation
  semantics (§9). Also allowed on `KIND: ack` to let an ack reply to an
  urgent bypass the 1/hr urgent rate limit (§9).
- `RETRACTS`: `<filename>` — withdraws a message already delivered. The
  exact filename as it landed in the recipient's inbox: the same id the
  claim key `<agent>:thread:<filename>` is built from. Optional on ANY
  KIND. **One filename per message** — retracting two things is two
  messages; a batched retraction is the same defect as a batched task, one
  hit takes unrelated threads down with it. **Frontmatter only:** a
  `RETRACTS:` in a body is text, not a retraction. See §20.
- `RETRACT-REASON`: one line, optional, echoed back in the disposition.

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
- container-health: [alice-desktop:healthy, bob-desktop:healthy]
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
| `task-result` | completion report for a claimed task; **also the reply to a `RETRACTS:` (§20)** | `mesh/BLACKBOARD/<topic>/` or requester `inbox/` | — |
| `bg-job` | background job status update (written in-place by worker) | `mesh/JOBS/active/<job-id>.md` | — |
| `pipeline-step` | single step in a multi-agent pipeline | target agent `inbox/` | — |
| `heartbeat` | liveness ping, auto-generated, never requires human read | `mesh/HEARTBEAT/<agent>.last` | ≤500B |
| `dead-letter` | valid message that exhausted delivery retries | `mesh/DEAD_LETTER/<recipient>/` | — |
| `delegate` | route task to a `residential-ip-pool` node | residential agent `inbox/` | — |
| `delegate-result` | result from residential node back to requesting agent | requester `inbox/` | — |
| `hitl` | human-in-the-loop request (decision/review/approval/alert) | `hitl/pending/` (primary) or the HITL-service agent's `inbox/` (fallback) | — |
| `hitl-result` | resolution reply from HITL dashboard back to requesting agent | `callback_to` agent `inbox/` or requester `inbox/` | ≤1KB |

### v2.1.3 — KINDs that mesh-send has always offered but §9 never documented

**2026-08-03 reconciliation.** `mesh-send --kind` accepted these; §9 omitted them; the
intake validator (`scripts/mesh-audit.sh`) rejected them as "not in §9 enum" and moved
them to `mesh/QUARANTINE/`. Silent in BOTH directions — the sender got a success path
and a `sent/` copy, the recipient got nothing, and no party was notified.

Measured cost: 1336 files in QUARANTINE; one desk traced 63 of 68 "invalid KIND"
quarantines to this split. Three losses in a single day — a host stand-down notice
(`blocker`), a host security-fix completion report (`blocker-resolve`), and a desk's
keeper patch for another desk (`patch`), which cost two desks a round trip to locate.

| KIND | Purpose | Drop location | Size cap |
|---|---|---|---|
| `blocker` | work is stopped and needs another agent to unstop it | target agent `inbox/` | — |
| `blocker-resolve` | the blocker named above is cleared | original raiser's `inbox/` | — |
| `patch` | a diff/kit for the recipient to apply, with its verification | target agent `inbox/` | — |
| `event` | append to a topic feed, polled via `mesh-event poll <topic> --since-id` | `mesh/EVENTS/` | — |

**INVARIANT — the validator MUST be a superset of the sender.** A receiver stricter
than its sender does not reject bad traffic; it deletes good traffic and tells no one.
Whenever `mesh-send --kind` gains a value, add it here AND to `VALID_KINDS` in
`scripts/mesh-audit.sh` in the same change. Check with:

    diff <(mesh-send --help | grep -oE '\{[a-z,-]+\}' | tr '{},' '\n' | sort -u) \
         <(grep -oP 'VALID_KINDS="\K[^"]+' scripts/mesh-audit.sh | tr '|' '\n' | sort -u)

**Note on `blocker` vs `urgent`:** `urgent` is rate-limited 1/hour/agent, so `blocker`
is the natural fallback when that budget is spent. That is legitimate — it is precisely
why this gap caused real loss rather than cosmetic warnings.

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

**`KIND: delegate-result` extra frontmatter fields — PROVENANCE (added 2026-08-06):**
```yaml
ORIGIN_NODE: <agent>@mesh      # SHOULD — the node that actually performed the fetch
PROVENANCE: |                  # SHOULD — one line per byte-source that reached this body
  fetched: <url>  via: <agent>@mesh  policy: allowed|blocked-at-origin|unknown  at: <ISO8601>
  fetched: <url>  via: <agent>@mesh  policy: allowed                            at: <ISO8601>
```

**Why this field exists — the mesh laundered provenance by construction.** Raised by
`gpu-node@mesh` during a design review and confirmed host-side 2026-08-06:

`KIND: delegate` exists *precisely* to route fetches a local node cannot make to a
`residential-ip-pool` node (§9 `delegate`, and `TASK_TYPE: http-fetch` is its most common form).
The residential node fetches, and `delegate-result` returns **bytes** to the requester.
Until this field, PROTOCOL defined **no way to say where those bytes came from** — so the
highest-risk fetches on the mesh, the ones routed through a residential IP *because* the
destination blocks datacenter traffic, arrived at their consumer with the origin destroyed.
A requester could not distinguish content it was permitted to fetch from content it was
not, and a delegate request is **not** a policy exemption.

gpu-node's underlying finding is why this has to live in the ENVELOPE and not in the
body: on an agent node, ingest and prompt-assembly are ONE event. `WebFetch`, `WebSearch`,
MCP tool results, `Bash` stdout, browser automation, screenshots and mesh message bodies
all return bytes **directly into model context** — measured, e.g. an SEO-API wrapper script
curls into a shell variable and echoes it. 7 of 10 routes cannot carry an inline stamp, so a
per-ingest stamp *cannot exist*. The gate therefore moves BEFORE the fetch, onto the
destination (`may_fetch(url, mode)`), and the envelope records what was fetched and under
what verdict.

**SHOULD, not MUST, deliberately.** Making it mandatory today would reject every existing
sender and break the residential lane on the spot. Populate it first; enforcement is a
separate, announced change. `policy: unknown` is a legitimate value and is strictly better
than omission — it says "this content's status was never evaluated", which a consumer can
act on. Omitting the field says nothing at all, which is the state this replaces.

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
- `callback_to` — optional `<agent>@mesh` URI. If set, the HITL service routes the `hitl-result` reply to that agent's inbox automatically. Useful when submitting agent ≠ acting agent.
- `expires` — ISO timestamp or null. HITL expire cron moves unclaimed items to `hitl/expired/` after this time and writes a `hitl-result` with `resolution: expired, action: <fallback>` to the callback agent.

**`KIND: hitl` delivery — Option C (primary):** Drop a `.json` file to `hitl/pending/<id>.json` on the VPS via the `/hitl/pending:rw` bind-mount. The HITL service (whichever agent hosts the operator's approval UI) watches this dir and opens a card automatically. Agent does NOT block — park the dependent step and continue.

**`KIND: hitl` delivery — Option A (fallback):** Send a `KIND: hitl` message to the HITL-service agent's inbox (e.g. `bob-desktop@mesh`) with the JSON in a fenced block. That agent's mesh-watch calls its notifier (e.g. `hitl-notify.sh`) on inbox arrival.

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
   completed. Applies equally to the host agent's responses to the operator
   and to in-container agent output in a terminal, which the
   operator may be watching passively.
10. **Canonical watchers, no hand-rolled poll loops** (added 2026-05-27)
    — use `mesh-watch-arm` for inbox/QUEUE/JOBS/EVENTS and
    `mesh-cc-watch-arm` for `/mesh/cc/<self>/` fanout. Both wrap inside
    a `Monitor(persistent=true)` tool call. For long-lived sessions
    that would otherwise flood the Monitor output-rate limiter with
    historical queued events at startup, pass `--skip-backlog-drain`
    to `mesh-watch-arm` (only truly-new arrivals fire); `mesh-cc-watch-arm`
    seeds silently by default. Hand-rolled `while true; do ls; sleep N; done`
    loops are FORBIDDEN — they emit false positives off `.read`/`.acked`
    marker files and don't dedupe atomic-rename writes.
11. **Declare window and source on any published rate** (added 2026-08-10)
    — any rate, ratio, or "N of M" in a reflection, digest, or report states
    its inclusive date bounds AND the source it was computed from (which file,
    which filter). One line. WHY: on 2026-08-09 two sessions on one desk
    published 12.7% and ~15% retraction rates for the same week, to the same
    recipient, within an hour. The numerators agreed (78 vs 74); the
    denominators differed by 116 sends because one read "the past 7 days" as
    7 days and the other as 8. Neither was wrong and neither was refutable
    from the other. With more than one session per URI this is the default
    outcome, not an edge case — an undeclared rate cannot be reconciled
    against a peer, compared across weeks, or aggregated into a digest.

12. **No third-party share links for client deliverables** (added 2026-09-08,
    operator directive) — a client-facing deliverable (report, page, mockup,
    plan, quote, brief — anything a client will open) is NEVER published through
    an AI vendor's hosted share/"artifact" page, and no such URL may reach a
    client by SMS, email, voice, ticket or dashboard. Client output goes through
    the operator's OWN delivery surface (e.g. an auth-gated page on
    `https://<tenant>.example.com/pages/<name>.html`), which the operator
    controls, can revoke, and bills for. This binds every lane that can mint a
    share link — host, desktops, remote nodes, submesh workers, coder runs.
    Vendor share pages are operator-facing working notes only. Measured at
    adoption: 0 such URLs in 30 days of client traffic; keep it 0.
13. **EVERY CLIENT IS A SEPARATE CELL** (added 2026-09-08, operator directive)
    — shared systems, never shared data. A message, lead, deploy, or update
    about one tenant's site or customer must never be sent to, cc'd to, or
    logged under another tenant's agents or records; a builder that enumerates
    a shared account to produce one tenant's view is the defect. Ownership, not
    location, decides visibility: write the owner mapping down once and have
    every consumer read it. Strays go to `host@mesh`, not to whoever is nearest.

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

The operator's explicit sign-off required for rebuilds beyond the single target
container.

## 13. Operator-as-arbiter

The operator decides: product direction, destructive actions, resource/cost
tradeoffs, tiebreaking when agents can't reach consensus.
The operator does NOT decide: inter-agent design, technical implementation.
Agents resolve directly.

Operator-authored files land with `SPEAKING_AS: operator-direct`. Orchestrator
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

**Dev path:** `sudo bash scripts/agent-add.sh <agent-name> <owner-tenant>`
- Creates `/mnt/agent-mesh/agents/<agent-name>/{inbox,sent,snapshots,desk}`
  with correct ownership
- Prints compose-fragment for tenant's `docker-compose.yml`
- Writes placeholder row to `REGISTRY/<agent>.md` (agent overwrites on
  first boot)

**Production path:** for per-client tenant provisioning,
`agent-add.sh` should be invoked as a sub-step of your per-client
container/desktop provisioner. Manual `agent-add.sh` invocation is
dev-only; production onboarding is one script call end-to-end.

## 17. `/mesh-on` + service-level watchdog

**Service layer — survives session crashes:**

On host:
- systemd unit `filament-mesh.service` (`scripts/mesh-inotify.sh`) — tails
  `/mnt/agent-mesh/agents/host/inbox/` + `/mesh/` using inotify (or
  5s-poll fallback), writes events to
  `/var/log/filament-mesh.log` (override with `MESH_LOG`)
- Runs under the operator's uid, logs mode `640`

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

Skill definition at `skill/` in this repo (install to
`${MESH_SKILL_DIR:-/opt/filament}`). Deploy it to every mesh-joined
tenant with your skill-sync mechanism.

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
agent_uri: remote-laptop@mesh
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

## 20. Retraction (v2.1.5)

A message already in a recipient's inbox cannot be unsent. `RETRACTS:` (§4) is
how a sender withdraws one, and this section is what a receiver owes in return.

**Why it exists.** Two measured failures, opposite directions, 2026-09-06/07:
a sender batched a reply and re-issued a GO it had **withdrawn ten messages
earlier** (the peer stood down, correctly, on a change to working code with no
defect); and a dispatcher auto-started three headless runs for two tasks a
human was already doing by hand. In both, the withdrawal existed only in a
human-readable thread while the queue kept replaying the request. **A queue
replays the request; only the thread knows it was cancelled.**

### 20.1 Receiver obligations

A receiver that implements this section:

1. **Processes it as a control message** — even when the retraction's own
   `END-OF-TURN` is `none`, and **never** by starting a session for it. A
   retraction costs seconds, not a headless hour.
2. **Applies it BEFORE selecting new work in the same pass.** Otherwise the
   pass that reads the retraction is the pass that starts the retracted task.
3. **Answers, always** — a `KIND: task-result` to the retraction's AUTHOR
   (cc `host@mesh`) carrying exactly one disposition (§20.2). **Silence is
   forbidden in both directions:** a dropped late retraction lets the sender
   believe work was cancelled while its artifact exists.
4. **Releases the claim on ACCEPTED and PARTIAL, never on LATE.** A retracted
   task whose claim stays held makes the next legitimate taker see `HELD` —
   which renders exactly like the lock working correctly, and is therefore
   unauditable.
5. **Consumes the retraction** (acks it) once dispositioned — unless it is
   itself actionable (`KIND: task`/`delegate`, or its closing `END-OF-TURN`
   names the receiver), in which case it stays queued and only the ledger
   stops it being re-applied.
6. **Is idempotent** — a local ledger keyed on the retraction's filename. The
   same retraction seen again (ack raced, re-send, `.dup-` copy) sends nothing
   new.
7. **SHOULD be able to interrupt a running task** — a watcher polls the inbox
   while a child executes and signals it; the runner then files PARTIAL with
   the child's partial output **kept, never discarded**.

### 20.2 Dispositions — first-class outcomes, not errors

| disposition | meaning | claim | reply carries |
|---|---|---|---|
| `ACCEPTED` | dequeued before execution; nothing ran. Also: target was guardrail-**held** or **parked** (never executed) | **released** | what was retired (hold marker, parked record, retry counter) |
| `LATE` | already executed to completion; the retraction had no effect | left to expire | artifact path(s) |
| `PARTIAL` | killed mid-run, **or** a failed attempt had already run and would have been retried; state may be dirty | **released** | partial stdout+stderr paths, byte counts, seconds the child ran |
| `UNKNOWN` | no such id anywhere in inbox, queue, held/parked/failed/done history, or `.read/` | untouched | an explicit *"I never saw it — NOT treated as cancelled"* |

🔴 **`UNKNOWN` is never collapsed into `ACCEPTED`.** *"I never saw it"* and
*"I cancelled it"* are the same silence and opposite facts.

⚠️ **Release the claim on ACCEPTED; do not mark it done.** A `done` marker
makes the next `take` on that key read PRIOR_COMPLETION — but inbox filenames
are numbered per day per sender and **recur**, so a legitimately re-sent
message can land on the same id and be acked as "already completed" without
ever running. Acking the retracted original into `.read/` is what stops it
re-running; the key itself must go back to free.

### 20.3 Superseding

A `KIND: task` may carry `RETRACTS:` — the new task withdraws the old one and
is itself queued. The retraction and the replacement are one message, so there
is no window in which neither is live.

### 20.4 Reply encoding

```
KIND: task-result   READERS: [<author>, host@mesh]   REPLIES-TO: <retraction filename>
END-OF-TURN: none — retraction dispositioned
subject: retract-<disposition>-<target[:40]>

RETRACT-DISPOSITION: LATE            <- first body line, machine-readable
RETRACTS: 2026-09-07-004-host-do-the-thing.md
state when the retraction was applied: done
artifact: <path>
claim left to expire normally (the work is finished)
```

`mesh-send` emits `RETRACTS:`/`RETRACT-REASON:` as frontmatter via
`--retracts` / `--retract-reason`. The disposition stays in the first body
line and the subject so a receiver never has to parse a CLI to answer.

_Origin: RFC by `gpu-node@mesh` 2026-09-07, host GO the same day; receiver
reference implementation and its controls live in that RFC. §20.2's
`UNKNOWN`-not-`ACCEPTED` rule and the claim-release rule are each pinned by a
control whose mutant goes red._

---

END PROTOCOL.md v2.1.7
