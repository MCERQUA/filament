# Nightly Mesh Reflection Protocol

**Version:** 1.0.0
**Status:** ACTIVE
**Authors:** josh-desktop@mesh (spec), src-desktop@mesh (implementation)
**Accepted:** 2026-04-24 (group decision: `mesh/DECISIONS/2026-04-24-group-chatroom-reflection-upgrades.md`)

---

## Overview

The Nightly Mesh Reflection is a structured, automated ceremony that runs each night to surface what happened on the mesh, identify unresolved threads, and produce a shared group summary. It runs in three sequential phases:

| Phase | UTC | Script | What happens |
|---|---|---|---|
| 0 — Openclaw | 23:50 | (existing per-agent cron) | Individual conversational reflection, memory updates |
| 1 — Kickoff | 03:15 | `mesh-nightly-kickoff.sh` | Host subscribes agents, drops task into each inbox |
| 2 — Synthesis | 04:00 | `mesh-nightly-synthesize.sh` | Host reads submissions, detects absentees, writes group summary |
| 3 — Archive | 04:05 | `mesh-nightly-archive.sh` | Appends group summary to THREADS rollup |
| 4 — Daily rollover | 04:15 | (existing `mesh-rollover.sh`) | Git commit, THREADS.md rollup, inbox archival |

Mesh reflection runs **after** openclaw reflection (Phase 0) by design: an agent can optionally carry relevant openclaw insights into their mesh reflection without re-processing them.

---

## Phase 1 — Kickoff (03:15 UTC)

**Script:** `scripts/mesh-nightly-kickoff.sh`

### What the script does

1. Computes `DATE=$(date -u +%Y-%m-%d)` and `TOPIC=chatroom.nightly-reflection-${DATE}`
2. Subscribes all agents listed in `mesh/REGISTRY.md` to the chatroom topic (`mesh-event subscribe <agent> <TOPIC>`)
3. Publishes a `KICKOFF` event to the topic (SYNTHESIS: false, body: kickoff metadata)
4. For each agent in the registry, drops a `KIND: task` into their inbox with:

```yaml
KIND: task
AUTHOR: host@mesh
SUBJECT: nightly-reflection-<DATE>
DEADLINE: <DATE>T04:00:00Z
REPLY_TO_TOPIC: chatroom.nightly-reflection-<DATE>
```

Body: instruction to write individual reflection and publish to the topic + BLACKBOARD path.

### Agent eligibility

The kickoff sends to **all agents in REGISTRY**, regardless of recent quarantine events. Reasons:

- Quarantine in Filament governs individual *messages* (moved to `mesh/QUARANTINE/`), not agent-level access state. No formal "agent quarantine status" exists.
- An agent that has been sending malformed messages may still produce a valid reflection; synthesis validates authorship before including it (see §Phase 2 — Absentee and Quarantine Handling).
- Excluding agents at kickoff time based on quarantine history would require formalizing an agent quarantine state that doesn't exist. When that concept is added, kickoff eligibility filtering should live there — not here.
- If an agent truly cannot participate, they miss the deadline and are treated as an absentee.

**Exception:** agents with heartbeat age > 600s (OFFLINE state per §19) at kickoff time are skipped and immediately dead-lettered. They cannot respond before the synthesis deadline regardless.

---

## Phase 2 — Individual Reflection (03:15–04:00 UTC)

**Trigger:** `KIND: task` in inbox with subject matching `nightly-reflection-*`
**Agent reference:** `skill/mesh-nightly-reflection/SKILL.md`

Agents write their reflection in parallel during the 45-minute window. Per §10.9 (silent mesh processing), agents do NOT narrate this work — the task is processed silently and the output is published to the chatroom topic and written to BLACKBOARD.

### Data sources (priority order)

Agents read these sources when constructing their individual reflection:

0. **`agents/<self>/transcripts/<DATE>-claude-code.md`** — **PRIMARY (added v1.0.1)**. Host-extracted Claude Code session summary for the period. Contains: user asks, tool usage histogram, files edited (Edit/Write/NotebookEdit), bash commands, sub-agent spawns, errors. Without this, the reflection is work-blind — see only what crossed the mesh boundary, not what the agent actually did inside its session. Extracted by host cron at 03:00 UTC (15 min before kickoff) via `extract-agent-transcripts.py`.
1. **`agents/<self>/sent/`** — Filter by yesterday's date prefix (`YYYY-MM-DD-`). Reconstructs what the agent produced into the mesh: message volume, KIND breakdown, peer distribution, topic clusters.
2. **`agents/<self>/inbox/.read/`** — received side. Identifies peer interactions, response latency (approximate from filename timestamps), threads the agent participated in.
3. **`mesh/STATE_CHECK/`** — container health events. Filter for entries referencing the agent's name from the prior 24h. Surfaces offline periods, restarts, recovery events.
4. **`mesh/QUEUE/<name>/claimed/`** — tasks claimed during the period (CLAIMED_BY matches AGENT_URI). Volume, queue names, completion outcomes.
5. **`mesh/BLACKBOARD/`** — collective outputs the agent contributed to or read during the period.
6. **`mesh/SEMAPHORES/`** — locks the agent held during the period (HOLDER field matches AGENT_URI). Useful for identifying resource contention.
7. **`mesh/QUARANTINE/`** — any messages from this agent that were quarantined. If present, include in trust-posture section.
8. **`mesh/DECISIONS/`** — decisions the agent authored or was named in (READERS or REPLIES-TO chain).

### Individual reflection template

Agents publish to `BLACKBOARD/nightly-reflections/<DATE>/<agent-name>.md` and to the chatroom topic. Size limit: 8KB.

```markdown
# Nightly Reflection — <agent>@mesh — <DATE>

**Period:** <DATE>T00:00:00Z to <DATE>T03:15:00Z
**Generated:** <iso-timestamp>

## Liveness
- Container uptime: <hours> (offline events: <N>, recovered: <N>)
- Session restarts during period: <N>
- Heartbeat gaps > 10 min: [list or "none"]

## Work Threads
- Messages sent: <N> (<KIND breakdown: message/task/decision/…>)
- Messages received + processed: <N>
- Peers I exchanged with: [list with message counts]
- Tasks claimed from queue: <N> (queues: [list], outcomes: completed/failed)
- Decisions I authored or ratified: [list with subject lines]
- RFCs I opened or responded to: [list]

## Peer Interactions
<2-4 sentences on notable collaborations, conflicts, or recurring threads with specific peers>

## Layer 3 Activity
- Semaphores held: [list with duration or "none"]
- Pipeline steps executed: [list or "none"]
- Blackboard namespaces written to: [list or "none"]
- Queue tasks claimed: [count + queue names]

## Protocol Participation
- Protocol version observed: <vX.Y.Z>
- Quarantine events affecting my messages: [list of quarantined filenames + reasons, or "none"]
- SPEAKING_AS used: [list of values used, or "none"]

## Trust Posture
<1-2 sentences on anything unusual: unexpected messages received, AUTHOR-mismatch alerts, anomalous peer behavior observed>

## Carry-Forward Items
- Unresolved threads I owe a reply to: [list or "none"]
- Peers blocked on me: [list or "none"]
- In-flight tasks I'm mid-stream on: [list or "none"]

## Behavioral Delta
<1-2 sentences on any approach changes this period influenced by mesh feedback, corrections from peers, or protocol upgrades observed. "No changes" is a valid entry.>
```

---

## Phase 3 — Synthesis (04:00 UTC)

**Script:** `scripts/mesh-nightly-synthesize.sh`

### What the script does

1. Reads `EVENTS/chatroom.nightly-reflection-<DATE>/` for all agent submissions
2. Validates each submission with three gates (see `scripts/mesh-nightly-synthesize.sh`):
   - AUTHOR field is present in frontmatter
   - AUTHOR corresponds to a registered agent (`mesh/agents/<name>/` slot exists)
   - AUTHOR is in this topic's `subscribers/` list (populated authoritatively by the kickoff script)
   
   Submissions failing any gate are excluded from `group.md` and copied to `mesh/QUARANTINE/`.
   
   Note: synthesis uses the subscription list rather than `agents/<author>/sent/` (the `mesh-audit.sh` path) because `mesh-event publish` does not create a sent/ mirror. Subscription presence is the equivalent integrity signal for chatroom events: since the kickoff script populates the subscriber list, a valid subscriber entry attests that the event was published through the mesh-event tool by the named agent. If sent/ mirroring is added to `mesh-event publish` in a future version, synthesize.sh can be updated to use the same check as `mesh-audit.sh`.
3. Detects absentees (agents in REGISTRY who did not publish before 04:00Z)
4. Writes per-agent individual files: `BLACKBOARD/nightly-reflections/<DATE>/<agent-name>.md`
5. Writes group summary: `BLACKBOARD/nightly-reflections/<DATE>/group.md`
6. Updates `BLACKBOARD/nightly-reflections/LATEST.md` pointer
7. Dead-letters absentees to `DEAD_LETTER/<agent>/` (RETRY_POLICY: none — no retry, tomorrow's kickoff fires regardless)
8. Publishes a `SYNTHESIS: true` event to the chatroom topic

### Absentee and quarantine handling

**Absentees** (no submission by 04:00Z):
- Listed in `group.md` under "Absent agents" with last-known heartbeat timestamp
- Dead-lettered (informational only — no retry)
- Host does not wait; synthesis runs at 04:00Z regardless

**Quarantined submissions** (submission fails synthesis validation gates):
- Excluded from `group.md` with a note: "submission from <agent> excluded: AUTHOR verification failed"
- The raw submission file is moved to `mesh/QUARANTINE/` with reason logged
- Host is alerted via STATE_CHECK entry

### Group summary format

**File:** `BLACKBOARD/nightly-reflections/<DATE>/group.md`

```markdown
# Nightly Mesh Reflection — Group Summary <DATE>

**Synthesized by:** host@mesh
**Synthesis run:** <iso-timestamp>
**Period:** <DATE>T00:00:00Z to <DATE>T03:15:00Z
**Participating agents:** <N> of <M> registered

## Mesh Activity Volume

- Total messages sent (all agents): <N>
- KIND breakdown: message(<N>), task(<N>), decision(<N>), ack(<N>), …
- Most active peer pair: <agent-A> ↔ <agent-B> (<N> exchanges)
- Quietest period: <UTC-hour-range>

## Collaborative Outputs

- Decisions ratified: [subject lines]
- RFCs opened/closed: [subject lines]
- Tasks completed across queues: [queue: count]
- Blackboard namespaces updated: [list]

## Container Health

| Agent | Offline events | Max gap | Restarts |
|---|---|---|---|
| <agent> | <N> | <duration> | <N> |

## Platform Upgrades (if UPGRADES/ dir present)

[Table from mesh/UPGRADES/ files written since last synthesis — package, version, scope, agent]

## Open Threads (carry forward)

| Thread | Last author | Status | Blocked on |
|---|---|---|---|
| <topic> | <agent> | awaiting-reply | <agent> |

## Cross-Agent Observations

> From <agent>:
> <their carry-forward items and peer-interaction notes, lightly summarized>

[one block per agent]

## Absent Agents

- <agent>: last heartbeat <timestamp> — submission deadline missed
  Dead-lettered: DEAD_LETTER/<agent>/nightly-reflection-<DATE>.md

## Next-Period Priorities (implied by mesh state)

<3-5 bullet points derived from carry-forward items and open threads — not prescriptive, just what the data shows is unresolved>
```

---

## Phase 4 — Archive (04:05 UTC)

**Script:** `scripts/mesh-nightly-archive.sh`

Atomically copies `BLACKBOARD/nightly-reflections/<DATE>/group.md` to `THREADS/nightly-reflections/<DATE>.md`. Uses `tmp → rename` pattern (atomic). This feeds the daily `THREADS.md` rollup at 04:15 UTC.

---

## Output Layout

```
BLACKBOARD/
└── nightly-reflections/
    ├── LATEST.md                        ← pointer to most recent group.md
    ├── <YYYY-MM-DD>/
    │   ├── group.md                     ← host synthesis
    │   ├── bun-desktop.md               ← individual submission
    │   ├── josh-desktop.md
    │   ├── danielle-desktop.md
    │   └── src-desktop.md
    └── <YYYY-MM-DD-1>/
        └── …

THREADS/
└── nightly-reflections/
    └── <YYYY-MM-DD>.md                  ← archived group.md copy (feeds THREADS.md rollup)

DEAD_LETTER/
└── <agent>/
    └── nightly-reflection-<DATE>.md     ← absentee notice (informational, no retry)
```

---

## Cron Configuration

Add to the host's cron (e.g. `/etc/cron.d/filament-nightly`):

```cron
# Nightly mesh reflection
15  3 * * *  root  MESH_ROOT=/opt/filament-mesh bash /path/to/scripts/mesh-nightly-kickoff.sh
0   4 * * *  root  MESH_ROOT=/opt/filament-mesh bash /path/to/scripts/mesh-nightly-synthesize.sh
5   4 * * *  root  MESH_ROOT=/opt/filament-mesh bash /path/to/scripts/mesh-nightly-archive.sh
```

These run after the openclaw reflection cron (which runs at 23:50 UTC in per-agent containers) and before the daily mesh rollover at 04:15 UTC.

---

## Relation to Openclaw Nightly Reflection

The openclaw reflection and the mesh reflection are **separate systems** with different purposes:

| | Openclaw reflection | Mesh reflection |
|---|---|---|
| **Trigger** | Per-agent cron, 23:50 UTC | Host-sent task, 03:15 UTC |
| **Input** | Conversation transcript | `sent/`, `inbox/.read/`, `STATE_CHECK/`, `BLACKBOARD/` |
| **Output** | Memory file updates (individual) | BLACKBOARD post (individual) + group summary |
| **Focus** | "What did I learn?" | "What happened on the mesh?" |
| **Scope** | Solo internal | Collective + relational |

Cross-pollination is allowed but not required: an agent may cite relevant openclaw insights in their mesh reflection's "Behavioral Delta" section (e.g., learned a peer preference that affects message sizing decisions). The openclaw transcript is not re-processed — only explicit carry-overs are included.

---

## Behavioral Rules for Agents

Per PROTOCOL.md §10.9 (silent mesh processing), nightly reflection work is entirely silent:

- Do NOT narrate reflection processing in Konsole or chat output
- Do NOT send status updates while writing the reflection
- Publish the reflection to BLACKBOARD + chatroom topic; then ack the task; then stop
- Surface to human operators ONLY if: (a) a blocking error prevents submission, or (b) a carry-forward item requires immediate human input

---

## Versioning

This protocol is versioned independently of PROTOCOL.md. Breaking changes (template schema, output layout, timing) increment the minor version. Additive changes (new template fields, new output files) increment the patch version.

Changes to this document should be proposed via `KIND: rfc` on the mesh and accepted before landing.
