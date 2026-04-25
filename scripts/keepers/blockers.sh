#!/usr/bin/env bash
# keepers/blockers.sh — escalate over-SLA blockers that nobody picked up.
#
# Existing mesh-blocker-check.sh stamps STATE_CHECK on over-SLA blockers
# (passive). This keeper goes further: drops a task to the BLOCKED_ON
# agent every 6h with the blocker context, until resolved.

set -uo pipefail
# helpers from parent

OPEN_FILE="${MESH_ROOT}/mesh/BLACKBOARD/blockers/OPEN.md"
[[ -r "$OPEN_FILE" ]] || { log "    blockers: no OPEN.md"; exit 0; }

# Parse OPEN.md per-blocker block (each starts with "## host:" or "## <agent>:")
current_agent=""
current_subject=""
current_blocked_on=""
current_age=""
current_resolution=""
current_status=""

while IFS= read -r line; do
    if [[ "$line" =~ ^##[[:space:]]([a-z-]+):[[:space:]](.+)$ ]]; then
        # Process previous block
        if [[ -n "$current_blocked_on" && -n "$current_subject" ]]; then
            blocked=${current_blocked_on%@mesh}
            redrop_subject="blocker-resolution-needed"
            last=$(last_redrop "$blocked" "$redrop_subject")
            if (( NOW - last >= 21600 )); then  # 6h between re-drops
                body_file=$(mktemp)
                cat > "$body_file" <<EOF
DEADLINE: 2026-04-30T00:00:00Z
PRIORITY: 2
QUEUE: blockers

KEEPER ACTIVE-PROMPT — there is an OPEN blocker waiting on you.

Subject: ${current_subject}
BLOCKED_ON: ${current_blocked_on}
Age: ${current_age}
Status: ${current_status}
RESOLUTION_PATHS: ${current_resolution}

This blocker has been open and is not being acted on. Please:
1. Read /mesh/BLACKBOARD/blockers/OPEN.md and locate this blocker
2. Either resolve it (mesh-blocker resolve <blocker-id> --by ${blocked})
3. Or comment in /mesh/agents/${blocked}/inbox/.read/ about why it's blocked-on-something-else
4. Or escalate via KIND: question

Silent processing per §10.9. Don't just ack — act.
EOF
                redrop_task "$blocked" "$redrop_subject" "$body_file"
                rm -f "$body_file"
            fi
        fi
        # Reset for next block
        current_agent="${BASH_REMATCH[1]}"
        current_subject="${BASH_REMATCH[2]}"
        current_blocked_on=""
        current_resolution=""
        current_status=""
        current_age=""
    elif [[ "$line" =~ ^-[[:space:]]age:[[:space:]](.+)·[[:space:]]SLA:[[:space:]](.+)·[[:space:]]status:[[:space:]](.+)$ ]]; then
        current_age="${BASH_REMATCH[1]}"
        current_status="${BASH_REMATCH[3]}"
    elif [[ "$line" =~ ^-[[:space:]]BLOCKED_ON:[[:space:]](.+)$ ]]; then
        current_blocked_on="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^-[[:space:]]RESOLUTION_PATHS:[[:space:]](.+)$ ]]; then
        current_resolution="${BASH_REMATCH[1]}"
    fi
done < "$OPEN_FILE"

# Don't forget the last block
if [[ -n "$current_blocked_on" && -n "$current_subject" ]]; then
    blocked=${current_blocked_on%@mesh}
    redrop_subject="blocker-resolution-needed"
    last=$(last_redrop "$blocked" "$redrop_subject")
    if (( NOW - last >= 21600 )); then
        body_file=$(mktemp)
        cat > "$body_file" <<EOF
DEADLINE: 2026-04-30T00:00:00Z
PRIORITY: 2
QUEUE: blockers

KEEPER ACTIVE-PROMPT — open blocker on you.

Subject: ${current_subject}
BLOCKED_ON: ${current_blocked_on}
Age: ${current_age}
RESOLUTION_PATHS: ${current_resolution}

Read /mesh/BLACKBOARD/blockers/OPEN.md, resolve or escalate.
EOF
        redrop_task "$blocked" "$redrop_subject" "$body_file"
        rm -f "$body_file"
    fi
fi

log "    blockers keeper run complete"
