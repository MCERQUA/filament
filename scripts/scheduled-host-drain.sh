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

LOCK=/tmp/scheduled-host-drain.lock
LOG=/home/mike/MIKE-AI/logs/scheduled-host-drain.log
exec 9>"$LOCK"
flock -n 9 || { echo "[$(date -u +%FT%TZ)] another drain in progress — exiting" >> "$LOG"; exit 0; }

. /home/mike/MIKE-AI/scripts/agent-mesh/filament-env.sh

unread=$(ls /mnt/agent-mesh/agents/host/inbox/2026-*.md 2>/dev/null | wc -l)
if [[ ${unread} -lt 1 ]]; then
    echo "[$(date -u +%FT%TZ)] inbox empty — skip drain" >> "$LOG"
    exit 0
fi

PROMPT=$(cat <<'EOF'
You are a host-mesh-drainer agent. Drain /mnt/agent-mesh/agents/host/inbox/.

PROCEDURE:
1. List unread: ls /mnt/agent-mesh/agents/host/inbox/2026-*.md
2. For each file, read frontmatter (KIND, AUTHOR, SUBJECT) and body
3. Decide:
   - KIND:ack/announcement/task-result → mesh-ack only
   - KIND:message    → reply if explicit ask, else ack
   - KIND:question   → REPLY with helpful answer; if you don't know, drop
                       KIND:announcement to host tagged "needs-mike" + ack
   - KIND:blocker    → REPLY with resolution OR escalate "needs-mike" + ack
   - KIND:urgent     → REPLY immediately + ack
4. Use mesh-send/mesh-ack from PATH

ENV: AGENT_URI=host@mesh, MESH_ROOT=/mnt/agent-mesh

CONTEXT (read if relevant):
  /mnt/agent-mesh/mesh/BLACKBOARD/ovui-lite/BRIEF.md
  /mnt/agent-mesh/mesh/BLACKBOARD/ovui-lite/submissions/src-desktop/CONVERSATION-PROOF.md
  /home/mike/.claude/projects/-home-mike-MIKE-AI/memory/MEMORY.md

RULES:
- Silent processing per PROTOCOL.md §10.9
- Never paste secrets (intel filter blocks Authorization: header literals)
- No destructive ops (rm, force push)
- Cap at 15 min — next cron picks up if incomplete
- Don't make architectural decisions — escalate "needs-mike"

Drain now. Report final inbox depth on exit.
EOF
)

START=$(date +%s)
echo "[$(date -u +%FT%TZ)] drain start — ${unread} unread" >> "$LOG"

export CLAUDE_CONFIG_DIR=/home/mike/.claude-drainer
mkdir -p "$CLAUDE_CONFIG_DIR"

timeout 900 /home/mike/.local/bin/claude \
    --dangerously-skip-permissions \
    --print "$PROMPT" \
    >> "$LOG" 2>&1 || echo "[$(date -u +%FT%TZ)] claude exited non-zero" >> "$LOG"

ELAPSED=$(( $(date +%s) - START ))
remaining=$(ls /mnt/agent-mesh/agents/host/inbox/2026-*.md 2>/dev/null | wc -l)
echo "[$(date -u +%FT%TZ)] drain end — ${remaining} unread (was ${unread}); elapsed ${ELAPSED}s" >> "$LOG"

sc_file="/mnt/agent-mesh/mesh/STATE_CHECK/$(date -u +%Y-%m-%dT%H%M%SZ)-host-scheduled-drain.md"
{
    echo "## host@mesh @ $(date -u +%FT%TZ)"
    echo "- scheduled-drain-unread-before: ${unread}"
    echo "- scheduled-drain-unread-after: ${remaining}"
    echo "- scheduled-drain-elapsed-sec: ${ELAPSED}"
} > "$sc_file"
