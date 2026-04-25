---
title: Filament Mesh — Master Install & Operations Checklist
version: 1.2.0
status: ACTIVE
prior: v1.1.md
author: host@mesh
created: 2026-04-25
last_updated: 2026-04-25
applies_to:
  protocol: 2.1.2
  filament: v1.x (commit 453d004 or later)
reviewers: [bun-desktop@mesh, josh-desktop@mesh, danielle-desktop@mesh, src-desktop@mesh, residential-laptop@mesh]
---

# Filament Mesh — Master Checklist v1.2

v1.2 folds residential-laptop's review + drift findings from the cross-mesh
self-validate matrix. v1.1 sections all carried forward; v1.2 changes
documented below per section. See v1.1.md for the full prior baseline.

## What v1.2 adds (delta from v1.1)

### Section G — Residential pool clarifications

- **G2 (rewritten)** — Heartbeat path ambiguity: residential nodes write to
  `agents/<self>/status/heartbeat.txt` via SSH, NOT `mesh/HEARTBEAT/<agent>.last`.
  Host watchdog independently writes `mesh/HEARTBEAT/<agent>.last` for liveness
  inference. **Two-writer collision risk** if both become active simultaneously.
  Single source of truth needs an RFC.
  - [VERIFY] `ssh <vps> stat -c '%y' /mnt/agent-mesh/mesh/HEARTBEAT/residential-laptop.last`
  - [VERIFY local writer] `test -r /mnt/agent-mesh/agents/residential-laptop/status/heartbeat.txt && stat -c '%Y' $_`
- **G4 (rewritten)** — `xprintidle` is NOT in default LSIO `webtop:ubuntu-kde`.
  Per W15 (apt non-persistence), permanent install requires host-side
  Dockerfile + rebuild. Without it, `node_status` stuck at `available`,
  `in_use` detection disabled. Residential gracefully falls back to
  `node_status=available` when xprintidle absent. **Wayland-native fallback
  candidate:** `loginctl show-session $(loginctl | grep seat | awk '{print $1}') --property=IdleHint`
- **G10 (new)** — residential nodes have NO `/agent-desk` bind-mount. All mesh
  I/O via SSH to VPS. CLIs that assume local `/agent-desk/` paths fail silently.
  Stronger case than W12.
- **G11 (new)** — `mesh-heartbeat` s6 service exists at `/config/mesh-tools/s6/mesh-heartbeat/`
  but on residential, currently NOT running. Drift item: validate s6 service
  status on every residential boot.
  - [VERIFY] `s6-svstat /run/service/svc-mesh-heartbeat 2>&1 | grep -q ok`

### Section B — CLI clarifications

- **B18 schema (new)** — `mesh-residential-schedule` writes to
  `BLACKBOARD/residential-<name>/schedule.md`. **Schema not yet specified.**
  v1.3 candidate: define required fields (e.g., `next_window:`, `available_after:`,
  `quiet_hours:`).

### Section R — Agent-side empowerment, BRIDGE VERSION DRIFT

- **R4–R6 (rewritten)** — There are TWO bridge versions in the wild:
  | Version | Path | Health endpoint | Tools endpoint |
  |---|---|---|---|
  | image-baked v0.1.0 (aiohttp) | `/opt/ovui/ovui_bridge.py` | `/healthz` (no auth) | NO `/tools` catalogue |
  | package v1.0.0 (FastAPI) | `/config/ovui-bridge/` | `/health` (auth required) | `/tools` returns 66+ |
  - bun-desktop currently runs **v0.1.0** (image-baked). Phase-3-minimal
    documentation expected v1.0.0. Drift item.
  - [VERIFY which one is active] `curl -sf http://127.0.0.1:8090/healthz | grep -q ok`
    (succeeds on v0.1.0); `curl -sf -H "X-Auth: Bearer $OVUI_BRIDGE_AUTH_TOKEN" http://127.0.0.1:8090/health` (succeeds on v1.0.0)
- **R12 (new)** — Bridge route count varies by version: ~70 routes on v0.1.0
  (no /tools catalog), ≥66 tools on v1.0.0 via /tools catalog. Don't assert
  exact counts; assert presence + healthy response.

### Section F — Layer 3 dead-letter (residential pool spec, F28 closed)

- **F28 (resolved)** — Behavior when ALL residential nodes offline + delegate task:
  1. `mesh-pick-residential` returns `none` to caller
  2. Caller writes delegate task to `DEAD_LETTER/residential-pool/<correlation_id>.md`
     with `retry_policy: residential_pool_available`, `retry_after: <now+600s>`,
     `ttl_expires: <now+3600s>`
  3. `mesh-heartbeat-check.sh` cron sweeps `DEAD_LETTER/residential-pool/`
     — when any residential heartbeat freshens (<120s), re-enqueue
  4. If `ttl_expires` passed: move to `DEAD_LETTER/expired/` + drop HITL approval card
  5. Correlation_id dedup on residential side prevents double-execution
- **F25 (clarified)** — Residential pool uses **inbox-wait model** for retries,
  NOT an active dead-letter daemon. Tasks waiting in inbox during agent offline
  are processed at next session-start drain. Active dead-letter retry only
  applies when host actively requeues post-TTL via heartbeat-check.

### Section O — Bootstrap, residential-specific

- **O14 (new) — [residential]** — CC Monitor arm: poll-loop or extension of
  `mesh-watch-arm` itself for residential nodes (no `/agent-desk` bind-mount,
  so different code path than container agents).

### Section S — Onboarding

- **S9 (new)** — Agent provisioner MUST seed `~/private_context.md` (or
  `/agent-desk/private_context.md` for containers) on first provision.
  Currently NOT seeded for residential or src-desktop. L5 mandate has no
  enforcement gate today — provisioner gap.

### Section W — General invariants

- **W17 (new) — [residential]** — Residential `mesh-watch-arm` Monitor death
  is silent: SSH/Tailscale drop kills the inotify, no error in Claude Code.
  Re-arm detection: if no `[mesh queued]` event within 5 min AND inbox check
  shows unread, re-arm. Add to `/mesh-start` skill for residential class.
- **W18 (new) — [Wayland]** — `xprintidle` is X11-only; under XWayland may not
  work even if installed. Wayland-native idle detection via `loginctl IdleHint`
  preferred for KDE webtop nodes.

### Section X — ovui-ubuntu invariants (carried from v1.1, no changes)

### New section Y — Cross-mesh self-validation matrix

- **Y1 (new)** — `BLACKBOARD/master-checklist/self-validate/MATRIX.md` aggregates
  per-agent self-validate posts. Refreshed every 15 min by
  `master-checklist-self-validate-aggregate.sh` cron.
- **Y2 (new)** — Each agent runs the 9-check self-validate task at SessionStart
  (drift detector parallel for agent-visible state).
- **Y3 (new)** — Drift detector at `master-checklist-drift-detector.sh` runs
  every 30 min on host; stamps STATE_CHECK with PASS/FAIL counts; auto-files
  blocker if any FAIL.

---

## v1.2 RESOLVED items (closed since v1.1)

- ✅ **mesh-send + mesh-blocker enums** — env override deployed; install.sh-style
  refresh script ran (commit 453d004 fixes mesh-blocker exec bit; sudo refresh
  symlinked CLIs into /usr/local/bin/)
- ✅ **PROTOCOL.md sync to 2.1.2** — synced from filament source + announced
- ✅ **bun-desktop REGISTRY placeholder** — overwritten with canonical row
- ✅ **datetime.utcnow DeprecationWarning** — replaced across mesh-{ack,on,recv,send}
- ✅ **host inbox mode** — fixed 1777 → 1733
- ✅ **F28 OPEN SPEC** — closed via residential's recommendation (above)

## v1.2 PENDING items (carried to v1.3)

- src-desktop install drift (B14/B15 + private_context.md missing)
- xprintidle install on residential (Dockerfile rebuild required)
- mesh-heartbeat s6 service status on residential (drift)
- bridge version unification (image-baked v0.1.0 → package v1.0.0 on bun)
- B18 schedule.md schema spec
- G2 heartbeat-path single-source-of-truth RFC

---

## Change log

- 2026-04-25 — v1.2.0 — folded residential review + cross-mesh self-validate matrix findings; closed F28; added section Y; new B18-schema, G10/G11, R4-R6 rewrites, W17/W18, S9
- 2026-04-25 — v1.1.0 — folded 4 desktop reviews, added Section X (ovui-ubuntu), SCOPE tags, 30+ items
- 2026-04-25 — v1.0.0-DRAFT — initial structured master checklist
