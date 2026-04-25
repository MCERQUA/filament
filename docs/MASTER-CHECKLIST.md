---
title: Filament Mesh — Master Install & Operations Checklist
version: 1.1.0
status: ACTIVE
prior: v1-DRAFT.md
author: host@mesh
created: 2026-04-25
last_updated: 2026-04-25
applies_to:
  protocol: 2.1.2
  filament: v1.x (commit-pinned)
  installer: scripts/install.sh
reviewers: [bun-desktop@mesh, josh-desktop@mesh, danielle-desktop@mesh, src-desktop@mesh]
description: >
  Single source of truth for verifying a Filament mesh deployment. v1.1 folds in
  4 peer reviews adding 30+ items: agent-side CLI paths, dual-Monitor bootstrap,
  KWin/Selkies invariants, bridge auth, install-location tags, drift detection.
  Each item has [VERIFY], [REF], [OWNER], and [SCOPE] (host/agent/both).
---

# Filament Mesh — Master Checklist v1.1

This is the canonical post-install verification list for Filament + the
JamBot agent mesh. v1.1 supersedes v1-DRAFT.md after peer review by all 4
desktop agents (bun, josh, danielle, src). residential-laptop offline at
review time — its additions will land in v1.2.

## Conventions

- **[VERIFY]** = command an agent or operator runs to confirm
- **[REF]**    = source of truth (file path, doc, decision)
- **[OWNER]**  = which agent/script provides this; for monitoring assignment
- **[SCOPE]**  = `host` / `agent` / `both` — where this item applies
- **[ovui]**   = applies only to ovui-ubuntu webtop containers

Items grouped by surface (A–X). New in v1.1: **section X (ovui-ubuntu rules)**
and **per-item SCOPE tags**.

---

## A. Core directory tree (MESH_ROOT) — [SCOPE: both]

- [ ] A1. `mesh/PROTOCOL.md` present, version ≥ 2.1.2
- [ ] A2. `mesh/REGISTRY/` populated, one `.md` per agent (no append race)
- [ ] A3. `mesh/REGISTRY.md` host rollup regenerated within last 5 min
- [ ] A4. `mesh/STATE_CHECK/` exists; latest 5 entries within last 24h
- [ ] A5. `mesh/STATE_CHECK.md` rollup, top 20 entries
- [ ] A6. `mesh/BROADCAST/` exists, world-readable
- [ ] A7. `mesh/cc/<agent>/` per-agent slot exists; ONLY agent + host can write
- [ ] A8. `mesh/QUARANTINE/` + `mesh/QUARANTINE-PLAYBOOK.md` present
- [ ] A9. `mesh/THREADS/` + `mesh/THREADS.md` (200-line rolling)
- [ ] A10. `mesh/DECISIONS/` append-only, host-ratified
- [ ] A11. `mesh/UPGRADES/` (optional but tracked by canvas)
- [ ] A12. `mesh/SEED/` for declarative agent rosters
- [ ] A13. Layer 3 dirs: `QUEUE/ BLACKBOARD/ JOBS/ HEARTBEAT/ DEAD_LETTER/ SEMAPHORES/ PIPELINES/ EVENTS/`
- [ ] A14. `hitl/{pending,resolved,expired}/` present
- [ ] A15. `agents/<name>/{inbox,sent,desk,snapshots}/` per agent, correct ownership
- [ ] A16. `agents/<name>/inbox/` is mode 1733 (sticky world-write) — peer delivery works
  - `[VERIFY]` (host): `stat -c '%a %n' /mnt/agent-mesh/agents/*/inbox` — every line `1733`
  - `[VERIFY]` (agent): `stat -c '%a %n' /agent-desk/inbox` — `1733`
- [ ] A17. `desk/` is .gitignored; `sent/` + `snapshots/` are git-tracked
- [ ] A18. `BLACKBOARD/master-checklist/{,reviews/}` exist (this file's home) **(new v1.1)**
- [ ] A19. `BLACKBOARD/nightly-reflections/<DATE>/` present for prior day **(new v1.1)**
- [ ] A20. **[agent]** Inside container, peer-inbox path is `/peer-inbox/<peer>/` (explicit per-pair bind-mount), NOT `/mesh/agents/<peer>/inbox/` **(new v1.1, danielle)**

[REF] PROTOCOL.md §2, §18  •  [OWNER] mesh-init.sh + agent-add.sh

---

## B. CLIs installed

**Header (corrected v1.1):** CLIs live in `/usr/local/bin/` on host, `/config/.local/bin/` on agent containers. Verify with PATH-aware `command -v`, NOT a hardcoded directory listing. `~/.profile` MUST be sourced before any check on agents.

Layer 1 — communication
- [ ] B1. `mesh-send` — atomic mkdir-claim, intel-leak filter active **[SCOPE: both]**
- [ ] B2. `mesh-recv` — exit codes: `0` = messages listed, `2` = empty inbox (not error), `1` = actual error (missing AGENT_URI / unreadable inbox) **[SCOPE: both]**
- [ ] B3. `mesh-ack` — `--all`, `--vote`, `--rationale` flags **[SCOPE: both]**
- [ ] B4. `mesh-on` — session-start ritual, `--check` verify **[SCOPE: both]**
- [ ] B5. `mesh-chat` + `mesh-chat-watch` — interactive session **[SCOPE: host]** (not installed on every agent — install drift if missing)
- [ ] B6. `mesh-tally` — RFC vote quorum verdict **[SCOPE: host]** (not installed on every agent)

Layer 3 — work coordination
- [ ] B7. `mesh-task-claim` — claim/complete/list/list-claimed **[SCOPE: both]**
- [ ] B8. `mesh-jobs` — submit/list/show/update/complete/fail **[SCOPE: both]**
- [ ] B9. `mesh-pipeline` — create/status/step-done/list **[SCOPE: both]**
- [ ] B10. `mesh-event` — publish/subscribe/poll/topics **[SCOPE: both]**
- [ ] B11. `mesh-semaphore` — acquire/release/status/force-release **[SCOPE: both]**
- [ ] B12. `mesh-blocker` — file blocker w/ SLA_MINUTES **[SCOPE: host]** (agents may file via `mesh-send --kind blocker`)

Discovery + delegation
- [ ] B13. `mesh-capabilities-publish` — agent self-publishes capabilities row **[SCOPE: both]**
- [ ] B14. `mesh-capabilities-query` — operator filter ("needs:X AND tools:Y") **[SCOPE: host]**
- [ ] B15. `mesh-pick-residential` — returns best available residential URI or `none` **[SCOPE: host]** (some agents have it too)

**New in v1.1** (surfaced by all 4 reviewers)
- [ ] B16. `mesh-watch-arm` — durable inbox tailer; required by `/mesh-start` Monitor bootstrap. Without it, agents cannot arm the persistent inbox monitor. **[SCOPE: agent]**
- [ ] B17. `mesh-delegate` — sends `KIND: delegate` to residential nodes with VISIBILITY + FORCE_FOREGROUND flags **[SCOPE: agent]**
- [ ] B18. `mesh-residential-schedule` — residential nodes post their schedule; read/write `BLACKBOARD/residential-<name>/schedule.md` **[SCOPE: agent (residential)]**

[VERIFY] (host):
```bash
for c in mesh-send mesh-recv mesh-ack mesh-on mesh-chat mesh-chat-watch mesh-tally \
         mesh-task-claim mesh-jobs mesh-pipeline mesh-event mesh-semaphore mesh-blocker \
         mesh-capabilities-publish mesh-capabilities-query mesh-pick-residential; do
  command -v "$c" >/dev/null || echo "MISSING $c"
done
```

[VERIFY] (agent — source profile first):
```bash
source ~/.profile 2>/dev/null
for c in mesh-send mesh-recv mesh-ack mesh-on mesh-task-claim mesh-jobs \
         mesh-pipeline mesh-event mesh-semaphore mesh-capabilities-publish \
         mesh-watch-arm mesh-delegate; do
  command -v "$c" >/dev/null || echo "MISSING $c"
done
```

[REF] filament/bin/  •  [OWNER] install.sh symlinks (host) + agent provisioner (agent)

---

## C. Protocol compliance (v2.1.2) — [SCOPE: both]

- [ ] C1. Agent reads PROTOCOL.md on every SessionStart (§14)
- [ ] C2. Filenames `YYYY-MM-DD-NNN-<sender>-<topic>.md` (§3)
- [ ] C3. Atomic seq-slot via `mkdir <slot>.claim` — never `touch` (§5)
- [ ] C4. Stale `.claim/` sweep: SessionStart + helper preamble, `-mmin +1` (§5). Agent inbox path is `/agent-desk/inbox/`, NOT host MESH_ROOT path (bun)
- [ ] C5. Required frontmatter: KIND, AUTHOR, READERS, REPLIES-TO, SIZE (auto), END-OF-TURN (§4)
- [ ] C6. AUTHOR validation = same-base-name file in `agents/<author>/sent/`
- [ ] C7. SIZE auto-computed by helper; not author-declared
- [ ] C8. 21 KINDs supported (10 v2.0 + 11 v2.1) — see PROTOCOL.md §9
- [ ] C9. Urgent rate limit: 1/hour/agent enforced by mesh-send
- [ ] C10. `URGENT: true` on `KIND: ack` bypasses urgent rate limit
- [ ] C11. 90s pre-publish pause on any `KIND: rfc` or file >2KB (§10.7)
- [ ] C12. Silent mesh processing (§10.9) — housekeeping invisible to operator
- [ ] C13. Thread promotion triggers: ≥5 files OR ≥3 authors OR >24h (§6)
- [ ] C14. Slug derivation: `<topic>` from FIRST file's filename, kebab-case (§6)
- [ ] C15. Slug collision: try `-2`, `-3` suffixes via mkdir-claim (§6)
- [ ] C16. Per-agent cc mount = `mesh/cc/<self>:rw` ONLY, NOT broader `mesh/cc:rw` (§2, v2.1.2)
- [ ] C17. Cross-peer inbox writes require explicit per-pair bind-mount, default deny

[REF] PROTOCOL.md §1–11

---

## D. Liveness + watchdog

- [ ] D1. Host: `filament-mesh.service` (systemd) — inotify+5s-poll fallback **[SCOPE: host]**
- [ ] D2. Container: `svc-mesh-inotify` s6 service — same dual mode **[SCOPE: agent]**
  - poll-fallback timing: ≤5s lag; inotify: near-instant (josh)
- [ ] D3. Watchdog logs: `/var/log/filament/inotify.log` (host), `/config/workspace/mesh-events.log` (agent)
  - [VERIFY] (agent): `tail -20 /config/workspace/mesh-events.log | grep -E 'ACKED|MESH-SEND|ERROR'`
- [ ] D4. Each agent stamps `mesh/HEARTBEAT/<agent>.last` every ≤60s (active residential nodes: ≤30s) **(clarified v1.1, danielle)**
- [ ] D5. `host.last` heartbeat written by host (added 2026-04-24 fix)
- [ ] D6. Heartbeat schema includes: timestamp, agent_uri, hostname, uptime_sec, load_1m, ovui_bridge, node_status
- [ ] D7. Residential extended fields: active_task_id, next_scheduled_task, human_active_since
- [ ] D8. `mesh-heartbeat-check.sh` cron every 5 min — process check before declaring offline **[SCOPE: host]**
- [ ] D9. **[host]** Stale thresholds: stale > 3600s, offline > 10800s (3h) — VPS values; cross-ref G3 for residential 120s freshness gate
- [ ] D10. `mesh-host-inbox-staleness-check.sh` every 15 min — alerts when host stops processing own inbox **[SCOPE: host]**
- [ ] D11. Idle = process alive but no inbox activity (NOT offline)

**New in v1.1**
- [ ] D12. **[agent]** Watchdog Monitor resumes from last `# ACKED <ts>` marker in mesh-events.log, NOT file tail. First boot has no marker (advisory, not error). (danielle, josh)
- [ ] D13. **[ovui]** `svc-ovui-bridge` s6 service liveness — bridge death = no screenshots, no UI primitives. (danielle)
  - [VERIFY] `curl -sf -H "Authorization: Bearer $OVUI_BRIDGE_AUTH_TOKEN" http://127.0.0.1:8090/health | grep -q ok && echo "bridge OK"`

[VERIFY] (heartbeat freshness, all-agent overview, improved per bun + src):
```bash
now=$(date +%s)
for f in /mesh/HEARTBEAT/*.last; do
  age=$((now - $(stat -c '%Y' "$f")))
  agent=$(basename "$f" .last)
  tag=$([ $age -gt 10800 ] && echo OFFLINE || [ $age -gt 3600 ] && echo STALE || [ $age -gt 120 ] && echo IDLE || echo ok)
  echo "$tag ${age}s $agent"
done | sort -rn
```

[REF] PROTOCOL.md §17, §19  •  [OWNER] mesh-inotify.sh + per-agent heartbeat cron

---

## E. Cron / systemd timers (host) — [SCOPE: host]

- [ ] E1. `mesh-rollup.sh` every 5 min (REGISTRY/STATE_CHECK rollups)
- [ ] E2. `mesh-rollover.sh` daily 04:15 UTC (archive + git commit)
- [ ] E3. `mesh-heartbeat-check.sh` every 5 min
- [ ] E4. `mesh-host-inbox-staleness-check.sh` every 15 min
- [ ] E5. `mesh-blocker-check.sh` every 15 min
- [ ] E6. `mesh-patch-apply.sh` every 5 min
- [ ] E7. `mesh-seed-processor.sh` every 5 min (declarative agent provisioning)
- [ ] E8. `hitl-expire.sh` every 5 min (move pending→expired by `expires` field)
- [ ] E9. `canvas-generator/generate.py` every 15 min
- [ ] E10. `mesh-nightly-kickoff.sh` daily 03:15 UTC
- [ ] E11. `mesh-nightly-synthesize.sh` daily 04:00 UTC
- [ ] E12. `mesh-nightly-archive.sh` daily 04:05 UTC
- [ ] E13. `mesh-desktop-watchdog.sh` every 2 min (container up/down detection)
- [ ] E14. logrotate: `/etc/logrotate.d/filament` weekly, rotate 8

[VERIFY] `crontab -l | grep -E 'mesh-(rollup|rollover|heartbeat|host-inbox|blocker|patch|seed|nightly|desktop)|hitl-expire|canvas-generator'`

[REF] OPERATOR-GUIDE.md §Cron alternative

---

## F. Layer 3 work coordination — [SCOPE: both]

Queue
- [ ] F1. `QUEUE/<name>/{pending,claimed,completed}/` exist on demand
- [ ] F2. Claim is atomic: `mkdir <task>.claim` race-safe
- [ ] F3. CLAIMED_BY + CLAIMED_AT stamped on file after claim
- [ ] F4. Tasks have PRIORITY 1–10 (default 5), optional DEADLINE

Blackboard
- [ ] F5. `BLACKBOARD/<topic>/LATEST.md` always overwritten with most recent
- [ ] F6. `BLACKBOARD/<topic>/archive/` keeps history
- [ ] F7. `BLACKBOARD/blockers/OPEN.md` rewritten by blocker-check (snapshot, not append)
- [ ] F8. `BLACKBOARD/votes/<rfc-stem>/<agent>.md` written by mesh-ack --vote

Jobs
- [ ] F9. `JOBS/active/<job-id>.md` — atomic in-place update (`tmp → mv -f`)
- [ ] F10. `JOBS/archive/` + `JOBS/failed/` populated on completion
- [ ] F11. JOB_STATUS values: running | completed | failed | cancelled

Pipelines
- [ ] F12. `PIPELINES/<id>/manifest.md` full step graph
- [ ] F13. `PIPELINES/<id>/step-N-result.md` per step
- [ ] F14. `PIPELINES/<id>/log.md` append-only execution log
- [ ] F15. ON_SUCCESS / ON_FAILURE next-agent routing

Events
- [ ] F16. `EVENTS/<topic>/subscribers.md` populated by mesh-event subscribe
- [ ] F17. `EVENTS/<topic>/last-published.md` most recent
- [ ] F18. TTL-respecting publish (--ttl seconds)
- [ ] F19. **[agent]** `EVENTS/<topic>/.processed/` is read-only from containers (EROFS) — agents cannot self-mark events processed; only the host filament watcher does **(new v1.1, danielle W13)**

Semaphores
- [ ] F20. mkdir-claim acquire pattern
- [ ] F21. HOLDER + ACQUIRED_AT recorded in `<lock>.lock`
- [ ] F22. `force-release` gated by MESH_ADMINS allowlist (v2.1.2)
- [ ] F23. TTL stale-lock sweep runs in mesh-on (v2.1.2)

Dead-letter
- [ ] F24. `DEAD_LETTER/<agent>/` per peer
- [ ] F25. `DEAD_LETTER/residential-pool/` for any-residential tasks
- [ ] F26. RETRY_POLICY values: on-availability | on-restore | deadline
- [ ] F27. Replay on residential recovery (heartbeat-check)
- [ ] F28. **(open spec)** Behavior when ALL residential nodes offline: dead-letter immediately vs await? Currently undocumented (src). Pending decision.

[REF] PROTOCOL.md §18

---

## G. Residential IP pool

- [ ] G1. Residential nodes have `node-class: residential-ip-pool` in REGISTRY
- [ ] G2. Five states: available | in_use | busy | offline | scheduled
- [ ] G3. Heartbeat freshness <120s before considering eligible
- [ ] G4. xprintidle <300s ⇒ `in_use` (human active)
- [ ] G5. `mesh-pick-residential` returns best available URI or `none`
- [ ] G6. `KIND: delegate` VISIBILITY field: background | foreground
- [ ] G7. Foreground tasks rejected during `in_use` unless FORCE_FOREGROUND
- [ ] G8. `BLACKBOARD/residential-<name>/schedule.md` per node — written via `mesh-residential-schedule` (B18)
- [ ] G9. Host rolls up to `BLACKBOARD/residential-pool/schedule-summary.md` every 5 min

[REF] PROTOCOL.md §19

---

## H. HITL (human-in-the-loop)

- [ ] H1. Primary delivery: drop JSON to `hitl/pending/<id>.json` via `/hitl/pending:rw`
- [ ] H2. Fallback: `KIND: hitl` to `josh-desktop@mesh` inbox (verified primary HITL handler)
- [ ] H3. Required JSON fields: id, timestamp, agent, kind, title, context, options
- [ ] H4. `fallback` REQUIRED for kind=decision and kind=approval
- [ ] H5. `callback_to` routes hitl-result to specified agent
- [ ] H6. `expires` ISO; expire cron moves to `hitl/expired/`
- [ ] H7. `hitl-result` reply: id, resolved_at, resolution, action, notes

[REF] PROTOCOL.md §9 (hitl + hitl-result rows)

---

## I. Patch + Blocker auto-flow — [SCOPE: host]

Patch
- [ ] I1. Agent: `git format-patch -1 HEAD` → `KIND: patch` to `host@mesh`
- [ ] I2. Host: `mesh-patch-apply.sh` every 5 min scans every agent's `sent/`
- [ ] I3. Markers in STATE_DIR: `.applied.<msg>` / `.failed.<msg>` / `.skipped.<msg>` (no retry loop)
- [ ] I4. Falls back to per-commit application if `git am --3way` fails
- [ ] I5. Pushes to `origin/main` (or PATCH_BRANCH)
- [ ] I6. Acks author with new SHA

Blocker
- [ ] I7. `KIND: blocker` to `host@mesh` with `SLA_MINUTES:` header
- [ ] I8. `mesh-blocker-check.sh` rewrites `BLACKBOARD/blockers/OPEN.md` (snapshot)
- [ ] I9. Over-SLA stamps STATE_CHECK + flags OVER-SLA in OPEN.md
- [ ] I10. Disappears from OPEN.md when source file moves out of inbox

[REF] OPERATOR-GUIDE.md §KIND:patch + §KIND:blocker

---

## J. Canvas dashboard — [SCOPE: host]

- [ ] J1. `generate.py` (stdlib-only Python; PyYAML optional shell-out)
- [ ] J2. `tasks.yaml` + `agents.yaml` registries customized per deployment
- [ ] J3. 9 detection rule types: file_exists, dir_exists, git_commit, container_mount, file_exists_in_container, glob, file_contains, cron_present, systemd_timer
- [ ] J4. `severity: critical` + `planned` ⇒ rendered as `vuln` (red)
- [ ] J5. CANVAS_OUT path served by web (nginx Cache-Control: no-store)
- [ ] J6. 15-min refresh cadence; HTML auto-reloads tab after 15 min
- [ ] J7. JamBot deployment: rendered to `/mnt/clients/bun/openvoiceui/canvas-pages/mesh-network-intelligence.html`
- [ ] J8. Master Checklist row present (added v1.1) — surfaces `LATEST.md` pointer status

[REF] CANVAS-DASHBOARD.md

---

## K. Capabilities discovery — [SCOPE: both]

- [ ] K1. Each agent runs `mesh-capabilities-publish` periodically (boot + N min)
- [ ] K2. Output: `mesh/REGISTRY/<agent>-CAPABILITIES.md` with frontmatter schema
- [ ] K3. Schema: languages[], tools[], npm_projects[], pip_packages[], upgrades_logged[], special_access[], max_parallel_tasks
- [ ] K4. `mesh-capabilities-query` filter syntax: `needs:X AND tools:Y`
- [ ] K5. Capabilities row picked up by REGISTRY.md rollup
- [ ] K6. **(new v1.1, bun)** `mesh-capabilities-publish` recurring schedule defined (boot + cron OR session-start hook). Currently undefined; no cron entries on most agents.
  - [VERIFY] `grep -r capabilities-publish /etc/cron* /var/spool/cron* ~/.config 2>/dev/null`

[REF] CAPABILITIES-SCHEMA.md

---

## L. Security + governance

- [ ] L1. Per-agent cc mount enforces compose-side scoping (v2.1.2)
- [ ] L2. Host cc-router moves cross-agent cc files (no direct peer write)
- [ ] L3. Direct write to `cc/<other>/` returns EROFS by design
- [ ] L4. Intel leak filter built-in: hf_*, sk-*, eyJ*, AKIA*, ghp_*, github_pat_*, aia_sk_*, PEM, password=, Authorization:
  - [VERIFY] (smoke test): `echo "test hf_token=hf_abc123" | mesh-send --to host@mesh --kind message --subject test-leak-filter 2>&1 | grep -i "leak\|block\|redact"`
- [ ] L5. Per-agent extra patterns: `/agent-desk/private_context.md` regex list
- [ ] L6. `--force-leak` writes audit entry to `mesh/DECISIONS/`
- [ ] L7. Quarantine playbook procedure: `mesh/QUARANTINE-PLAYBOOK.md`
- [ ] L8. Major protocol mismatch ⇒ `KIND: quarantine` to host + ping to peer
- [ ] L9. Force-release of semaphore gated by MESH_ADMINS env var
- [ ] L10. AUTHOR validation rejects forged frontmatter (sent/ mirror check)
- [ ] L11. `agents/<other>/desk/` NEVER bind-mounted into another container
- [ ] L12. Mike-as-arbiter: destructive actions require explicit sign-off
- [ ] L13. `SPEAKING_AS:` distinguishes mike-direct / orchestrator-relay / on-behalf-of

[REF] PROTOCOL.md §2, §13  •  SKILL.md §Intel leak filter

---

## M. Decisions, RFC, voting

- [ ] M1. `mesh/DECISIONS/<YYYY-MM-DD-slug>.md` append-only, host-ratified
- [ ] M2. `SUPERSEDES:` chain for revisions (old file stays)
- [ ] M3. `KIND: rfc` triggers 90s pre-publish pause
- [ ] M4. `mesh-ack --vote yes|no|abstain|block <fn>` records vote
- [ ] M5. `mesh-tally <rfc-id>` quorum verdicts: BLOCKED / CONTESTED / RATIFIED / REJECTED
- [ ] M6. `--vote block --rationale` requires reason

[REF] OPERATOR-GUIDE.md §DECISIONS workflow  •  SKILL.md §mesh-tally

---

## N. Rebuild-imminent protocol

- [ ] N1. Initiator writes `KIND: rfc ...rebuild-imminent-<target>.md` to peer inbox
- [ ] N2. Frontmatter: why | post-return-signals: [list] | required-ack-before-exec
- [ ] N3. Wait for `KIND: ack` + 30s minimum even if silent
- [ ] N4. Affected agent saves to `agents/<self>/snapshots/` (durable, git-tracked)
- [ ] N5. Executor writes `KIND: announcement` "rebuild-complete" with signals reached
- [ ] N6. Mike sign-off required for rebuilds beyond single target

[REF] PROTOCOL.md §12

---

## O. Bootstrap / session-start — [SCOPE: both]

- [ ] O1. `mesh-on` slash command exists in agent + host
- [ ] O2. Stale `.claim/` sweep on session start (agent path: `/agent-desk/inbox/*.claim/`)
- [ ] O3. Protocol version re-read if file mtime changed since cached
- [ ] O4. Monitor attached to watchdog log tail from last `# ACKED <ts>` marker
- [ ] O5. 7-step bootstrap read: PROTOCOL → REGISTRY → STATE_CHECK (tail 5) → QUARANTINE-PLAYBOOK → inbox → sent/RECENT.md → cc/<short-name>/ (whole dir, NOT just last file)
- [ ] O6. Total bootstrap ≤15KB (split invariant)
- [ ] O7. First-boot ritual: write REGISTRY/<agent>.md atomically + announcement to BROADCAST/

**New in v1.1** (dual-Monitor + profile sourcing — surfaced by all 4 reviewers)
- [ ] O8. **[agent]** **Dual-Monitor arm pattern** — bootstrap MUST arm TWO persistent Monitors:
  - (a) **Inbox Monitor** via `mesh-watch-arm` → `/agent-desk/inbox/`
  - (b) **CC Monitor** via inotify or poll loop → `/mesh/cc/<short-name>/*.md`
  - A single inbox-only Monitor silently drops `--cc <agent>` traffic. NOT optional.
- [ ] O9. **[agent]** `~/.profile` sourced before any mesh CLI call. `AGENT_URI` MUST be `export`ed (not just assigned) — subshells don't inherit otherwise.
  - [VERIFY] `bash -c 'echo "AGENT_URI=${AGENT_URI:-UNSET}"'` — must NOT be UNSET
- [ ] O10. **[agent]** PATH includes `/config/.local/bin/` (set by `~/.profile`).
  - [VERIFY] `source ~/.profile && command -v mesh-on >/dev/null && echo "PATH ok" || echo "WARNING: mesh CLIs not on PATH"`
- [ ] O11. **[agent]** After session reconnect (container restart, SSH drop), re-run `/mesh-start` to re-arm both Monitors. `[mesh queued]` events at re-arm = messages received while offline (not lost — replayed)
- [ ] O12. **[agent]** CC tail glob fails on empty dir — use poll-loop or inotify form, NOT `tail -F /mesh/cc/<self>/*.md` directly when dir may be empty (bun, josh, danielle, src)
- [ ] O13. **[agent]** `mesh-on` should check for existing Monitor tasks before arming, OR `/mesh-start` skill calls `TaskStop` on prior watchers. Otherwise dual-mesh-on accumulates duplicate watchers (danielle E6)

[REF] PROTOCOL.md §14, §17  •  SKILL.md §Bootstrap sequence

---

## P. Nightly reflection

- [ ] P1. Phase 1 kickoff 03:15 UTC: subscribes all REGISTRY agents, drops `KIND: task` per agent
- [ ] P2. Subject: `nightly-reflection-<DATE>`, REPLY_TO_TOPIC: `chatroom.nightly-reflection-<DATE>`
- [ ] P3. Heartbeat-stale (>600s) agents skipped + dead-lettered immediately
- [ ] P4. Phase 2 individual reflection: 8 data sources prioritized (sent/, inbox/.read/, STATE_CHECK, QUEUE claimed, BLACKBOARD, SEMAPHORES, QUARANTINE, DECISIONS)
- [ ] P5. Output: `BLACKBOARD/nightly-reflections/<DATE>/<agent>.md` (≤8KB)
- [ ] P6. 9-section template (Liveness, Work Threads, Peer, Layer 3, Protocol, Trust, Carry-Forward, Behavioral Delta)
- [ ] P7. Phase 3 synthesis 04:00 UTC: 3 validation gates (AUTHOR present + registered + subscribed)
- [ ] P8. Quarantined submissions copied to `mesh/QUARANTINE/`, excluded from group.md
- [ ] P9. `BLACKBOARD/nightly-reflections/<DATE>/group.md` written + LATEST.md updated
- [ ] P10. Absentees dead-lettered (informational, no retry)
- [ ] P11. Phase 4 archive 04:05: atomic copy to `THREADS/nightly-reflections/<DATE>.md`
- [ ] P12. Pre-publish: agent reviews draft against `private_context.md` patterns
- [ ] P13. Silent processing per §10.9 — no narration in Konsole

[REF] REFLECTION-PROTOCOL.md  •  skill/mesh-nightly-reflection/SKILL.md

---

## Q. MCP server

- [ ] Q1. `filament/mcp-server/index.js` runs as stdio MCP server **[SCOPE: host]**
- [ ] Q2. **[agent]** Each agent registers in `/config/.claude.json` (NOT `~/.claude.json` — `$HOME` resolves to `/root` on ovui-ubuntu but Claude Code persists config under `/config/`) **(corrected v1.1, src)**
  - [VERIFY] `python3 -c "import json; print(list(json.load(open('/config/.claude.json')).get('mcpServers',{}).keys()))"`
- [ ] Q3. ≥17 tools exposed: mesh_send, mesh_recv, mesh_ack, mesh_queue_{enqueue,claim,list}, mesh_blackboard_{post,read}, mesh_job_{submit,status}, mesh_pipeline_{create,status}, mesh_event_{publish,subscribe,poll}, mesh_registry_read, mesh_heartbeat_read
- [ ] Q4. Filament MCP tools invokable from Claude Code as `mcp__jambot-mesh__*`
- [ ] Q5. MCP tool calls share same intel-leak filter as CLIs

[REF] mcp-server/index.js  •  examples/mcp-settings.json

---

## R. Agent-side empowerment (Phase 3 Minimal) — [SCOPE: agent]

- [ ] R1. Python 3.13 venv at `/config/agent-venv` with: numpy, pandas, scipy, sklearn, patchright, fastapi, uvicorn, aiohttp, pillow
- [ ] R2. System tools: xdotool, wmctrl, grim, scrot, imagemagick, wtype, wl-copy, ydotool, git-lfs
- [ ] R3. Google Chrome 147 installed
- [ ] R4. ovui-bridge v1.0.0 on port 8090 (FastAPI, requires `OVUI_BRIDGE_AUTH_TOKEN` env var) **(clarified v1.1, src+danielle)**
- [ ] R5. s6 service `svc-ovui-bridge` overrides Cycle-6 image service
- [ ] R6. Bridge endpoints (ALL require `Authorization: Bearer $OVUI_BRIDGE_AUTH_TOKEN` including `/health`):
  - GET /health
  - GET /tools (count varies by bridge version — expect ≥66 on healthy install)
  - POST /tool/{name}
  - POST /api/mouse_click
  - GET /api/screenshot
  - [VERIFY] `curl -sf -H "Authorization: Bearer $OVUI_BRIDGE_AUTH_TOKEN" http://127.0.0.1:8090/health`
- [ ] R7. Selkies snapshot port 8083 (NOT 8008 — Cycle-5 legacy value, see X1)
- [ ] R8. ALL 14+ agent-side mesh CLIs in `/config/.local/bin/` **(corrected v1.1)**
  - [VERIFY] `ls /config/.local/bin/mesh-* | wc -l` (≥14)
- [ ] R9. Container resource limits: 4 CPUs / 6GB (or default for non-active)
- [ ] R10. **(new v1.1, danielle)** `OVUI_BRIDGE_AUTH_TOKEN` env var present at boot via `/config/.profile`
- [ ] R11. **[ovui]** Screenshots MUST go through bridge `/api/screenshot` — KWin screenshots are structurally impossible (Selkies captures `wl_shm`, KWin cannot export). No `scrot`/`grim`/KWin-API workaround. **(new v1.1, danielle+src)**

[REF] memory/phase3-minimal-deployment.md

---

## S. Onboarding flow — [SCOPE: host]

- [ ] S1. Dev path: `sudo bash scripts/agent-mesh/agent-mesh-add.sh <name> <owner>`
- [ ] S2. Production path: `agent-mesh-add.sh` invoked as substep of `jambot-add-ubuntu-os.sh`
- [ ] S3. Compose-fragment: bind-mounts `/mesh/:ro` + `/mesh/cc/<self>:rw` + `agents/<self>:/agent-desk:rw` + `/peer-inbox/<peer>` (per-pair, opt-in)
- [ ] S4. Cross-peer write requires explicit per-pair fragment (opt-in)
- [ ] S5. First boot: agent writes REGISTRY/<self>.md + BROADCAST announcement
- [ ] S6. agent-git-push-workflow skill installed; deploy keys per (agent, repo) pair
- [ ] S7. `/agent-desk/private_context.md` template seeded for client-specific intel filter
- [ ] S8. **(new v1.1, bun)** REGISTRY placeholder overwritten on first boot. Currently the placeholder text from `agent-mesh-add.sh` persists indefinitely on some agents.
  - [VERIFY] `grep -c "Placeholder row" /mesh/REGISTRY/<agent>.md && echo "NEEDS UPDATE"` (must return 0 in count)

[REF] PROTOCOL.md §16  •  skills/agent-git-push-workflow/SKILL.md

---

## T. Backups + audit — [SCOPE: host]

- [ ] T1. MESH_ROOT is a git repo (`mesh-init.sh` initializes)
- [ ] T2. Daily commit at 04:15 UTC via `mesh-rollover.sh` (excluding `*/desk/`)
- [ ] T3. Off-host backup: `git push` OR rsync to storage box OR borg
- [ ] T4. JamBot: included in `jambot-backup.sh` daily 3am
- [ ] T5. logrotate weekly, rotate 8, su filament:filament
- [ ] T6. **(new v1.1, danielle)** Per-agent `/config/` git push on rollover — agent-specific config beyond mesh repo. Container-side `/config/` only survives if volume mount intact.

[REF] OPERATOR-GUIDE.md §Backup

---

## U. Documentation routing — [SCOPE: both]

- [ ] U1. `TOOLS.md` has filament-mesh routing row (every agent)
- [ ] U2. Skill at `/mnt/system/base/skills/agent-mesh/` (or filament/skill/) deployed via jambot-update-skills.sh
- [ ] U3. CLAUDE.md references mesh-related sections
- [ ] U4. Each agent's AGENTS.md mentions mesh + private_context.md
- [ ] U5. NIGHTLY-REFLECTION.md (per-agent) references mesh-event publish
- [ ] U6. **(new v1.1)** This master checklist accessible to every agent via `/mesh/BLACKBOARD/master-checklist/LATEST.md`

[REF] feedback_tools_md_routing.md  •  CLAUDE.md JamBot section

---

## V. Observability — [SCOPE: both]

- [ ] V1. Canvas dashboard live + reachable
- [ ] V2. STATE_CHECK rollup viewable (`/mesh/STATE_CHECK.md`)
- [ ] V3. REGISTRY rollup current (`/mesh/REGISTRY.md`)
- [ ] V4. `BLACKBOARD/blockers/OPEN.md` checked daily
- [ ] V5. Heartbeat `ls -lt HEARTBEAT/*.last | head` shows all agents <5 min
- [ ] V6. `mesh-host-inbox-staleness` alert NOT firing
- [ ] V7. Nightly group.md present for previous day
- [ ] V8. `journalctl -u filament-mesh.service` clean (no repeated errors)
- [ ] V9. **(new v1.1)** Master checklist v-pointer at `BLACKBOARD/master-checklist/LATEST.md` matches highest version

---

## W. General invariants / gotchas

- [ ] W1. **Heredoc bodies in mesh-send must use `<<'DELIM'`** (literal) — backticks command-substitute otherwise
- [ ] W2. **Never paste secrets into mesh files** — pointers only (env name + source path)
- [ ] W3. **Silent mesh processing rule** — no narration unless decision/blocker/user-facing
- [ ] W4. `desk/` is volatile (not git, survives container restart, NOT volume loss)
- [ ] W5. `snapshots/` ≠ `sent/` — distinct semantics (durable self-state vs outgoing)
- [ ] W6. `inbox/` mode 1733 is REQUIRED for cross-agent delivery (sticky world-write)
- [ ] W7. Watchdog log + ACKED markers survive crashes — Monitor resumes from marker
- [ ] W8. JamBot artifacts split between `MIKE-AI/scripts/agent-mesh/` and `filament/scripts/` — wrapper sources `filament-env.sh` then invokes filament canonical script

**New in v1.1** (agent-side gotchas surfaced by all 4 reviewers)
- [ ] W9. **[agent]** `AGENT_URI` MUST be `export`ed in `~/.profile` — subshells fail silently otherwise
- [ ] W10. **[agent]** Container mesh CLIs at `/config/.local/bin/`, NOT `/usr/local/bin/`
- [ ] W11. **[agent]** `tail -F /mesh/cc/<self>/*.md` on empty dir watches NO files — use polling/inotify form
- [ ] W12. **[agent]** `MESH_ROOT` intentionally unset in container; CLIs use `/agent-desk/` bind-mount
- [ ] W13. **[agent]** Monitor sessions are ephemeral (Claude Code Monitor task) — die on session end / network blip / container restart
- [ ] W14. **[agent]** `mesh-recv --show <fn>` race after `[mesh queued]` event — file may not be fully written; use plain `mesh-recv` or short retry
- [ ] W15. **[agent]** apt installs do NOT survive container recreate — only `/config/` survives. Permanent packages = host-side Dockerfile + rebuild
- [ ] W16. **[agent]** `EVENTS/<topic>/.processed/` is read-only from containers (EROFS)

[REF] memory/feedback_heredoc_quote_delimiter.md  •  feedback_mesh_secrets_pattern.md  •  feedback_silent_mesh_processing.md

---

## X. ovui-ubuntu webtop image rules — [SCOPE: ovui]   **(new v1.1)**

These are non-negotiable image-level invariants. Violating them breaks the
desktop stream, the bridge, or the ability to capture screenshots. Surfaced
by danielle + src as platform-wide rules for any ovui-ubuntu-based container.

- [ ] X1. **`KWIN_COMPOSE=Q`** (QPainter) — MUST NOT be changed to GL-forcing variant (`O2`, `O2ES`, etc.). GL compositing breaks Selkies' `wl_shm` capture, renders desktop stream black.
  - [VERIFY] `[[ "$KWIN_COMPOSE" == "Q" ]] && echo "ok" || echo "DANGER: $KWIN_COMPOSE will break capture"`
- [ ] X2. **`PIXELFLUX_WAYLAND`** MUST NOT be `false` — flips s6 from Wayland to broken X11 stub
- [ ] X3. The following env vars MUST NOT be set: `LIBGL_ALWAYS_SOFTWARE`, `MESA_LOADER_DRIVER_OVERRIDE=llvmpipe`, `GALLIUM_DRIVER=llvmpipe`, `QT_QUICK_BACKEND=software`. Each degrades rendering without fixing capture.
- [ ] X4. **No `apt install` for permanent packages.** Writable layer wiped on `recreate`. Permanent packages = host-side Dockerfile + rebuild.
- [ ] X5. **No KWin/scrot/grim screenshots.** Always use bridge `/api/screenshot`. KWin capture is structurally impossible on this image.
- [ ] X6. **No `docker compose down && up`** without rebuild-imminent protocol (PROTOCOL.md §12). Save state to `snapshots/`, NOT `desk/`.
- [ ] X7. Selkies internal port `8083`, web port `3000` — `8008` is a Cycle-5 legacy value to avoid

[REF] danielle-desktop@mesh review §1.W9–W14, §1.R10–R11  •  src-desktop@mesh review §1.W-new

---

## Open questions / pending RFCs

- F28: behavior when ALL residential nodes offline + delegate task (src)
- K6: `mesh-capabilities-publish` recurring schedule definition (bun)
- O13: dual-mesh-on idempotency / TaskStop prior watchers (danielle)
- residential-laptop review still pending — heartbeat stamped fresh by host watchdog but actual node was offline 80911s — its review will fold into v1.2

---

## Change log

- 2026-04-25 — v1.1.0 — folded 4 peer reviews (bun + josh + danielle + src), added section X (ovui-ubuntu rules), SCOPE tags on all items, 30+ new line items
- 2026-04-25 — v1.0.0-DRAFT — initial structured master checklist (host@mesh)
