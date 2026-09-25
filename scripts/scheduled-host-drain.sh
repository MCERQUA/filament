#!/usr/bin/env bash
# scheduled-host-drain.sh — spawn a real LLM session every 30 min to
# drain host inbox.
#
# Cron-driven file shuffling cannot reply to novel questions. Pattern
# auto-responder catches the recurring ones; this catches the rest.
#
# Spawns a one-shot Claude Code session (`claude -p`) with a focused
# prompt: read host inbox, reply or ack each item, exit.

set -uo pipefail

# Optional site bindings (MESH_ROOT, LOG_DIR, PATH for mesh-*). Nothing is
# sourced unless FILAMENT_ENV names an existing file.
if [[ -n "${FILAMENT_ENV:-}" && -f "${FILAMENT_ENV}" ]]; then
    # shellcheck disable=SC1090
    . "${FILAMENT_ENV}"
fi
MESH_ROOT="${MESH_ROOT:-/mnt/agent-mesh}"
LOCK="${LOCK:-/tmp/scheduled-host-drain.lock}"
LOG="${LOG_DIR:-${HOME}/.local/state/filament/logs}/scheduled-host-drain.log"
mkdir -p "$(dirname "$LOG")"
# Extra files the drainer should read for context (one path per line).
HOST_DRAIN_CONTEXT="${HOST_DRAIN_CONTEXT:-${MESH_ROOT}/mesh/PROTOCOL.md}"
HOST_INBOX="${MESH_ROOT}/agents/host/inbox"
exec 9>"$LOCK"
flock -n 9 || { echo "[$(date -u +%FT%TZ)] another drain in progress — exiting" >> "$LOG"; exit 0; }

unread=$(ls "${HOST_INBOX}"/[0-9][0-9][0-9][0-9]-*.md 2>/dev/null | wc -l)
if [[ ${unread} -lt 1 ]]; then
    echo "[$(date -u +%FT%TZ)] inbox empty — skip drain" >> "$LOG"
    exit 0
fi

# Unquoted heredoc on purpose: ${MESH_ROOT}/${HOST_INBOX}/${HOST_DRAIN_CONTEXT}
# expand. The prompt body must therefore contain no other $ or backticks.
PROMPT=$(cat <<EOF
You are a host-mesh-drainer agent. Drain ${HOST_INBOX}/.

PROCEDURE:
1. List unread: ls ${HOST_INBOX}/[0-9][0-9][0-9][0-9]-*.md
2. For each file, read frontmatter (KIND, AUTHOR, SUBJECT) and body
3. Decide:
   - KIND:ack/announcement/task-result → mesh-ack only
   - KIND:message    → reply if explicit ask, else ack
   - KIND:question   → REPLY with helpful answer; if you don't know, drop
                       KIND:announcement to host tagged "needs-operator" + ack
   - KIND:blocker    → REPLY with resolution OR escalate "needs-operator" + ack
   - KIND:urgent     → REPLY immediately + ack
4. Use mesh-send/mesh-ack from PATH

ENV: AGENT_URI=host@mesh, MESH_ROOT=${MESH_ROOT}

CONTEXT (read if relevant):
${HOST_DRAIN_CONTEXT}

RULES:
- Silent processing per PROTOCOL.md §10.9
- Never paste secrets (intel filter blocks Authorization: header literals)
- No destructive ops (rm, force push)
- Cap at 15 min — next cron picks up if incomplete
- Don't make architectural decisions — escalate "needs-operator"

Drain now. Report final inbox depth on exit.
EOF
)

START=$(date +%s)
echo "[$(date -u +%FT%TZ)] drain start — ${unread} unread" >> "$LOG"

# Separate config dir so the drainer never shares (and races on) the
# interactive session's credentials/state file.
export CLAUDE_CONFIG_DIR="${DRAIN_CLAUDE_CONFIG_DIR:-${HOME}/.claude-drainer}"
mkdir -p "$CLAUDE_CONFIG_DIR"

# Pin a model explicitly: account-default silently picks the most expensive tier.
timeout 900 "${CLAUDE_BIN:-claude}" \
    --model "${DRAIN_MODEL:-sonnet}" \
    --dangerously-skip-permissions \
    --print "$PROMPT" \
    >> "$LOG" 2>&1 || echo "[$(date -u +%FT%TZ)] claude exited non-zero" >> "$LOG"

ELAPSED=$(( $(date +%s) - START ))
remaining=$(ls "${HOST_INBOX}"/[0-9][0-9][0-9][0-9]-*.md 2>/dev/null | wc -l)
echo "[$(date -u +%FT%TZ)] drain end — ${remaining} unread (was ${unread}); elapsed ${ELAPSED}s" >> "$LOG"

sc_file="${MESH_ROOT}/mesh/STATE_CHECK/$(date -u +%Y-%m-%dT%H%M%SZ)-host-scheduled-drain.md"
{
    echo "## host@mesh @ $(date -u +%FT%TZ)"
    echo "- scheduled-drain-unread-before: ${unread}"
    echo "- scheduled-drain-unread-after: ${remaining}"
    echo "- scheduled-drain-elapsed-sec: ${ELAPSED}"
} > "$sc_file"
