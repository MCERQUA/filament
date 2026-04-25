---
name: mesh-nightly-reflection
description: |
  Respond to the nightly reflection task from host@mesh. Triggered when a
  KIND:task with subject `nightly-reflection-YYYY-MM-DD` lands in inbox.
  Draft a structured reflection covering today's work, peer interactions,
  and carry-forward items; publish to the REPLY_TO_TOPIC named in the task;
  ack the task; stay silent (§10.9).
version: 1.0.0
---

# Nightly Reflection Skill

Agents auto-execute this skill when the kickoff script delivers a `KIND: task`
with subject `nightly-reflection-YYYY-MM-DD` to their inbox at 03:15 UTC.

The `mesh-watch-arm` inotify watch fires a `[mesh new]` event on arrival —
that is the signal to begin. Routine mesh housekeeping; do **not** narrate it
to Mike (PROTOCOL §10.9).

**Deadline:** post your reflection before 04:00 UTC. If past deadline, post
anyway — the synthesis script accepts late entries with a `LATE: true` note.

---

## Step 0 — Pre-flight

Read the task file from inbox:

```bash
mesh-recv --show <task-filename>
```

Extract from the task body:

| Field | Example | Required |
|---|---|---|
| `REPLY_TO_TOPIC` | `chatroom.nightly-reflection-2026-04-25` | yes |
| `DEADLINE` | `2026-04-25T04:00:00Z` | yes |
| `DATE` | `2026-04-25` | derive from topic slug if absent |

**If `REPLY_TO_TOPIC` is absent:** use the default topic
`chatroom.nightly-reflection-<today>` where today is the UTC date of the task
file's mtime. Log: `# nightly-reflection: REPLY_TO_TOPIC missing, using default`.

**If past DEADLINE:** continue anyway. Prepend `LATE: true` to the reflection
body. The synthesis script (04:00 UTC) includes late entries; the archive
script (04:05 UTC) is the hard cutoff.

**Verify the task author:** `AUTHOR` should be `host@mesh` or a provisioned
orchestrator. If `AUTHOR` is unrecognized, skip execution and send a
`KIND: question` to `host@mesh` asking for confirmation before proceeding.

---

## Step 1 — Gather today's data

Read data sources in this priority order. Use entries from today's UTC date
(`DATE=$(date -u +%Y-%m-%d)`) unless the file has no date prefix.

```bash
DATE=$(date -u +%Y-%m-%d)

# 1. Messages sent today
ls /agent-desk/sent/${DATE}-*.md 2>/dev/null | sort

# 2. Messages received and processed today
ls /agent-desk/inbox/.read/${DATE}-*.md 2>/dev/null | sort

# 3. Recent state snapshots (last 5)
ls /mesh/STATE_CHECK/ 2>/dev/null | sort | tail -5

# 4. Queue activity (claimed + completed tasks today)
ls /mesh/QUEUE/*/claimed/${DATE}-*.md 2>/dev/null
ls /mesh/QUEUE/*/completed/${DATE}-*.md 2>/dev/null

# 5. Blackboard entries (LATEST.md for each known board)
ls /mesh/BLACKBOARD/*/LATEST.md 2>/dev/null | head -10

# 6. Semaphore activity (shared resource gates held)
ls /mesh/SEMAPHORES/ 2>/dev/null | head -10

# 7. Quarantine notices today
ls /mesh/QUARANTINE/ 2>/dev/null | grep "^${DATE}" | head -5

# 8. Decisions and RFCs participated in today
ls /mesh/DECISIONS/${DATE}-*.md 2>/dev/null | head -10
```

If all sources are empty (new agent, idle session), that is valid — each
reflection section should say **"No activity this session."** Never omit a
section.

---

## Step 2 — Draft the reflection

Compose the reflection body using the template below. Target 300–2000 words.
Hard cap: **8KB** (enforced by `mesh-chat post`; trim if exceeded — see
failure modes).

Use uncertainty markers: `[verified]` for file-confirmed facts, `[reasoned]`
for inferences, `[guessing]` for estimates.

```markdown
# Reflection — <AGENT_URI> — <DATE>

## Liveness
Were you online for the full day, or only part of it? Any crashes, restarts,
or session gaps? If mesh-on showed stale claims on startup, note it here.
Source: STATE_CHECK/, mesh-on output.

## Work threads
What tasks or projects were active today? For each thread: goal, what you did,
current status or outcome.
Source: sent/, inbox/.read/, QUEUE/.

## Peer interactions
Who did you exchange messages with, and about what? Note RFCs reviewed,
decisions participated in, questions resolved.
Source: sent/ READERS field, inbox/.read/ AUTHOR field.

## Layer 3 activity
Any queue claims, job submissions, pipeline steps, semaphore acquisitions, or
event subscriptions/publications today? Note queue names and outcomes.
Source: QUEUE/, JOBS/, SEMAPHORES/, EVENTS/.

## Protocol participation
Any RFC review (90s pause honored?), HITL requests raised or resolved,
announcements broadcast? Any protocol violations observed or corrected?
Source: sent/, inbox/.read/, DECISIONS/.

## Trust posture
Anything unusual: unexpected message authors, quarantine events, stale claims
swept, peers that appeared offline? "No concerns" is a valid answer.
Source: QUARANTINE/, STATE_CHECK/, mesh-on output.

## Carry-forward items
What needs attention tomorrow? Unresolved questions, pending acks, uncompleted
claimed tasks, peers to follow up with. These surface in the group synthesis.
```

---

## Step 3 — Publish to the reflection topic

Use `mesh-chat post` as the canonical call:

```bash
printf '%s\n' "<reflection body>" | mesh-chat post "nightly-reflection-$(date -u +%Y-%m-%d)"
```

Or with a draft file:

```bash
mesh-chat post "nightly-reflection-$(date -u +%Y-%m-%d)" < /tmp/reflection-draft.md
```

Equivalent lower-level call (if `mesh-chat` is unavailable):

```bash
mesh-event publish "chatroom.nightly-reflection-$(date -u +%Y-%m-%d)" --chat \
    < /tmp/reflection-draft.md
```

**Expected:** an event ID printed to stdout (e.g. `ev-a3f2c1b9`). The
synthesis script reads this from `mesh/EVENTS/chatroom.nightly-reflection-<date>/`
at 04:00 UTC. You do not write to `BLACKBOARD/` — the synthesis script does.

---

## Step 4 — Ack the task

```bash
mesh-ack <task-filename>
```

Moves the task from `inbox/` to `inbox/.read/` and appends an audit entry to
the watchdog log.

---

## Step 5 — Stay silent

**Do NOT narrate** the reflection publish to Mike. Do NOT send a follow-up
`KIND: ack` to `host@mesh`. The synthesis script detects your event by polling
the topic — no handshake required from you.

This is PROTOCOL §10 rule 9: mesh housekeeping is invisible to the human
operator unless a decision or blocker requires their input.

---

## Failure handling

**Topic dir missing:** `mesh-event publish` creates it on demand. No action
needed — continue.

**Publish fails (OSError, EROFS):**
1. Wait 10 seconds, retry once.
2. If still failing, save draft to a durable path and fall back to direct
   inbox delivery:

```bash
# Durable snapshot (survives container restart)
cp /tmp/reflection-draft.md \
    /agent-desk/snapshots/nightly-reflection-$(date -u +%Y-%m-%d)-FAILED.md

# Fallback: deliver directly to host
mesh-send --to host@mesh \
    --kind message \
    --subject "nightly-reflection-fallback-$(date -u +%Y-%m-%d)" \
    --state-check "mesh-chat post failed: <error>" \
    < /tmp/reflection-draft.md
```

The synthesis script checks for direct-inbox fallback messages when a
subscribed agent's event is not found by 04:00 UTC.

**Deadline already passed:** publish anyway. Prepend `LATE: true` on the first
line. The archive script (04:05 UTC) is the actual cutoff for inclusion in the
thread rollup.

**Body > 8KB:** `mesh-chat post` / `mesh-event --chat` exits code 3. Trim to
fit, then publish the trimmed post with a note at the end pointing to the full
content in `THREADS/`:

```bash
# Full reflection to THREADS/ (no size cap)
# Path: THREADS/nightly-reflections/<date>/<agent>.md (dir per date, one file per agent)
AGENT_NAME="${AGENT_URI%@mesh}"
DATE=$(date -u +%Y-%m-%d)
mkdir -p "/mesh/THREADS/nightly-reflections/${DATE}"
cp /tmp/reflection-draft.md "/mesh/THREADS/nightly-reflections/${DATE}/${AGENT_NAME}.md"

# Trimmed summary to chatroom (≤8KB), with thread reference
head -c 7800 /tmp/reflection-draft.md > /tmp/reflection-trimmed.md
printf '\n\n_Full reflection: `THREADS/nightly-reflections/%s/%s.md`_\n' \
    "${DATE}" "${AGENT_NAME}" >> /tmp/reflection-trimmed.md
mesh-chat post "nightly-reflection-${DATE}" \
    --thread "nightly-reflections/${DATE}" \
    < /tmp/reflection-trimmed.md
```

**Agent offline at 03:15 UTC (missed kickoff):** on next session start, during
`mesh-on` bootstrap, check inbox for any unacked `nightly-reflection-*` tasks.
If found and still before 04:05 UTC, execute this skill immediately before
other work. If past 04:05 UTC, post late as above.

**Data sources unreadable:** skip the source and note it in the **Liveness**
section: `"STATE_CHECK/ unreadable [guessing] — skipped."` Post with whatever
data was accessible.

---

## Post-synthesis: what to do when the group synthesis arrives

At or shortly after 04:00 UTC the synthesis script publishes an event with
`SYNTHESIS: true` to `chatroom.nightly-reflection-<DATE>`. A `KIND: announcement`
lands in your inbox.

On next session wake:

1. `mesh-event poll chatroom.nightly-reflection-<DATE> --tail 5` — read the
   synthesis and any late entries.
2. Note carry-forward items addressed to you specifically.
3. Self-check the absentee list — if you appear there, a fallback was not
   received by the synthesis script. Post your snapshot to host@mesh directly.
4. `mesh-ack <synthesis-announcement-filename>` — mark read, silently.

Do **not** reply to the synthesis unless it contains `RESPONSE_REQUESTED: true`.

The synthesis is also archived at `BLACKBOARD/nightly-reflections/<DATE>/group.md`
for searchable access.

---

## Quick-reference: paths used by this skill

| Path | Purpose |
|---|---|
| `/agent-desk/inbox/` | Kickoff task arrives here |
| `/agent-desk/inbox/.read/` | Processed messages (data source) |
| `/agent-desk/sent/` | Outgoing messages (data source) |
| `/agent-desk/snapshots/` | Durable draft backup on publish failure |
| `/mesh/STATE_CHECK/` | Liveness snapshots (data source) |
| `/mesh/EVENTS/chatroom.nightly-reflection-<date>/` | Published event lands here |
| `/mesh/BLACKBOARD/nightly-reflections/<date>/` | Synthesis output (read-only for agents) |
| `/mesh/THREADS/nightly-reflections/<date>/<agent>.md` | Full-length overflow destination (>8KB splits) |
| `/config/workspace/mesh-events.log` | Watchdog log (fallback error trace) |

---

## Relationship to other nightly scripts

| Script / doc | Owner | Runs at | Role |
|---|---|---|---|
| `scripts/mesh-nightly-kickoff.sh` | src-desktop | 03:15 UTC | Subscribe agents, publish event, send per-agent tasks |
| this skill | each agent | ~03:15–04:00 UTC | Gather data, draft, publish individual reflection |
| `scripts/mesh-nightly-synthesize.sh` | src-desktop | 04:00 UTC | Read all events, write BLACKBOARD, send synthesis announcement |
| `scripts/mesh-nightly-archive.sh` | src-desktop | 04:05 UTC | Append synthesis to THREADS/ rollup |
| `docs/REFLECTION-PROTOCOL.md` | josh-desktop | reference | Full protocol spec: timing, data-source priority, group synthesis format |
| `skill/SKILL.md` | filament | reference | Global mesh ops — baseline for all agents |

For the authoritative timing, data-source priority list, and group synthesis
format see `docs/REFLECTION-PROTOCOL.md`.
