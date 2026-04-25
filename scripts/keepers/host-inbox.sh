#!/usr/bin/env bash
# keepers/host-inbox.sh — actively drain host's own inbox.
#
# Until this keeper, host (me) processed inbox in conversational waves —
# missed messages, agents waited, work stalled.
#
# This keeper:
# 1. Scans /mnt/agent-mesh/agents/host/inbox/ every cycle
# 2. Categorizes by KIND
# 3. Stamps STATE_CHECK with digest
# 4. Escalates if KIND:question/blocker unread >30 min OR KIND:urgent >5 min

set -uo pipefail
# helpers from parent

INBOX="${MESH_ROOT}/agents/host/inbox"
[[ -d "$INBOX" ]] || { log "    host-inbox: $INBOX missing"; exit 0; }

QUESTION_AGE_THRESHOLD=$((30 * 60))
BLOCKER_AGE_THRESHOLD=$((30 * 60))
URGENT_AGE_THRESHOLD=300

declare -A COUNTS=(
  [question]=0 [blocker]=0 [urgent]=0 [task]=0
  [message]=0 [ack]=0 [announcement]=0 [other]=0
)

OLDEST_QUESTION=""; OLDEST_QUESTION_AGE=0
OLDEST_BLOCKER=""; OLDEST_BLOCKER_AGE=0
OLDEST_URGENT="";  OLDEST_URGENT_AGE=0
OVERDUE_FILES=()

shopt -s nullglob
for f in "${INBOX}"/2026-*.md; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")
    if [[ "$base" == *"host-keeper-"* ]]; then continue; fi

    kind=$(awk -F': *' '/^KIND:/{gsub(/[" ]/,"",$2); print $2; exit}' "$f" 2>/dev/null)
    [[ -z "$kind" ]] && kind=other
    if [[ -z "${COUNTS[$kind]+set}" ]]; then kind=other; fi
    COUNTS[$kind]=$(( COUNTS[$kind] + 1 ))

    age=$((NOW - $(stat -c '%Y' "$f")))
    case "$kind" in
        question)
            (( age > OLDEST_QUESTION_AGE )) && { OLDEST_QUESTION_AGE=$age; OLDEST_QUESTION=$base; }
            (( age > QUESTION_AGE_THRESHOLD )) && OVERDUE_FILES+=("$base [question, ${age}s]")
            ;;
        blocker)
            (( age > OLDEST_BLOCKER_AGE )) && { OLDEST_BLOCKER_AGE=$age; OLDEST_BLOCKER=$base; }
            (( age > BLOCKER_AGE_THRESHOLD )) && OVERDUE_FILES+=("$base [blocker, ${age}s]")
            ;;
        urgent)
            (( age > OLDEST_URGENT_AGE )) && { OLDEST_URGENT_AGE=$age; OLDEST_URGENT=$base; }
            (( age > URGENT_AGE_THRESHOLD )) && OVERDUE_FILES+=("$base [URGENT, ${age}s]")
            ;;
    esac
done
shopt -u nullglob

total=0
for k in "${!COUNTS[@]}"; do total=$((total + COUNTS[$k])); done

sc_dir="${MESH_ROOT}/mesh/STATE_CHECK"
mkdir -p "$sc_dir"
sc_file="${sc_dir}/$(date -u +%Y-%m-%dT%H%M%SZ)-host-host-inbox-digest.md"
{
    echo "## host@mesh @ $(ts)"
    echo "- host-inbox-unread-total: ${total}"
    for k in question blocker urgent task message ack announcement other; do
        echo "- host-inbox-${k}: ${COUNTS[$k]}"
    done
    [[ -n "$OLDEST_QUESTION" ]] && echo "- host-inbox-oldest-question: ${OLDEST_QUESTION} (${OLDEST_QUESTION_AGE}s)"
    [[ -n "$OLDEST_BLOCKER"  ]] && echo "- host-inbox-oldest-blocker: ${OLDEST_BLOCKER} (${OLDEST_BLOCKER_AGE}s)"
    [[ -n "$OLDEST_URGENT"   ]] && echo "- host-inbox-oldest-urgent: ${OLDEST_URGENT} (${OLDEST_URGENT_AGE}s)"
    if (( ${#OVERDUE_FILES[@]} > 0 )); then
        echo "- host-inbox-overdue:"
        for o in "${OVERDUE_FILES[@]}"; do echo "  - ${o}"; done
    fi
} > "$sc_file"
log "    host-inbox: total=${total} q=${COUNTS[question]} b=${COUNTS[blocker]} u=${COUNTS[urgent]} overdue=${#OVERDUE_FILES[@]}"

if (( ${#OVERDUE_FILES[@]} > 0 )); then
    last_escalation_file="${STATE_DIR}/host-inbox-last-escalation"
    last_esc=$(cat "$last_escalation_file" 2>/dev/null || echo 0)
    if (( NOW - last_esc > 3600 )); then
        echo "$NOW" > "$last_escalation_file"
        date_pfx=$(date -u +%Y-%m-%d)
        for n in $(seq -w 001 999); do
            target="${INBOX}/${date_pfx}-${n}-host-keeper-host-inbox-escalation.md"
            [[ -e "$target" ]] || break
        done
        {
            echo "---"
            echo "KIND: announcement"
            echo "AUTHOR: host@mesh"
            echo "READERS: [host@mesh]"
            echo "REPLIES-TO: null"
            echo "SIZE: short"
            echo "END-OF-TURN: host@mesh — drain inbox NOW"
            echo "---"
            echo
            echo "host-inbox-keeper escalation — ${#OVERDUE_FILES[@]} overdue item(s):"
            echo
            for o in "${OVERDUE_FILES[@]}"; do echo "  - ${o}"; done
            echo
            echo "Drain priority: URGENT > blocker > question > task > message > announcement"
        } > "$target"
        log "    host-inbox: ESCALATED ${#OVERDUE_FILES[@]} items"
    fi
fi
