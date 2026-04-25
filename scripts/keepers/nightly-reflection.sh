#!/usr/bin/env bash
# keepers/nightly-reflection.sh — verify group.md was actually produced.
#
# The mesh-nightly-{kickoff,synthesize,archive} cron runs at 03:15/18:00/18:05
# UTC. If group.md does not appear in BLACKBOARD/nightly-reflections/<date>/
# within 30 min of synthesis cron, escalate.

set -uo pipefail
# helpers from parent

BLACKBOARD="${MESH_ROOT}/mesh/BLACKBOARD/nightly-reflections"

# After synthesis cron runs (18:00 UTC), give it 30 min, then verify.
SYNTH_HOUR=18
SYNTH_TODAY=$(date -u -d "today ${SYNTH_HOUR}:00" +%s)
GRACE=$((30 * 60))

if (( NOW < SYNTH_TODAY + GRACE )); then
    log "    nightly: pre-cron or in grace window — skipping"
    exit 0
fi

DATE=$(date -u +%Y-%m-%d)
group_md="${BLACKBOARD}/${DATE}/group.md"

if [[ -r "$group_md" ]]; then
    # Verify it's not the broken-empty form (all agents absent + no submissions)
    body_lines=$(grep -cv '^#\|^$\|^---' "$group_md" 2>/dev/null)
    abs_only=$(awk '/^## Reflections/{found=1} found && /^- /{found_sub=1} END{exit found_sub?1:0}' "$group_md")
    if (( body_lines < 5 )); then
        # too short — likely broken
        subject="nightly-reflection-empty-group-md"
        last=$(last_redrop "host" "$subject")
        if (( NOW - last < 21600 )); then  # 6h cooldown
            log "    nightly: empty group.md detected but in cooldown"
            exit 0
        fi
        escalate "host" "nightly group.md for ${DATE} exists but is suspiciously short (${body_lines} body lines)"
        touch_redrop "host" "$subject"
        log "    nightly: ESCALATED empty group.md"
    else
        log "    nightly: group.md for ${DATE} exists and has content (${body_lines} lines)"
        reset_redrop "host" "nightly-reflection-missing"
        reset_redrop "host" "nightly-reflection-empty-group-md"
    fi
    exit 0
fi

# group.md is MISSING after grace window
subject="nightly-reflection-missing"
last=$(last_redrop "host" "$subject")
if (( NOW - last < 21600 )); then
    log "    nightly: missing group.md but in 6h cooldown"
    exit 0
fi

escalate "host" "nightly group.md for ${DATE} NOT produced — synthesis may have failed (check /home/mike/MIKE-AI/logs/mesh-nightly.log)"
touch_redrop "host" "$subject"

# Try auto-recovery: re-run synthesis
if [[ -x /home/mike/MIKE-AI/scripts/mesh-nightly-shipped/mesh-nightly-synthesize.sh ]]; then
    log "    nightly: auto-recovery — re-running synthesize"
    AGENT_URI=host@mesh MESH_ROOT="${MESH_ROOT}" \
        /home/mike/MIKE-AI/scripts/mesh-nightly-shipped/mesh-nightly-synthesize.sh "${DATE}" 2>&1 \
        | sed 's/^/      /' >> "${LOG}"
fi
