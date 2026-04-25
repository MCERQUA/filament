#!/usr/bin/env bash
# mesh-audit.sh — Quarantine audit cron for the Filament agent mesh.
#
# Walks every agent's inbox/, flags files whose AUTHOR: has no matching
# file in agents/<author>/sent/. Also checks for malformed frontmatter
# and invalid KIND values.
#
# Install via mesh-init.sh, or manually:
#   */15 * * * * MESH_ROOT=/opt/filament-mesh bash /path/to/scripts/mesh-audit.sh

set -euo pipefail

MESH_ROOT="${MESH_ROOT:-/opt/filament-mesh}"
AGENTS_DIR="${MESH_ROOT}/agents"
QUARANTINE_DIR="${MESH_ROOT}/mesh/QUARANTINE"
QUARANTINE_LOG="${QUARANTINE_DIR}/log.md"

mkdir -p "$QUARANTINE_DIR"
[[ -f "$QUARANTINE_LOG" ]] || echo "# Mesh Quarantine Log" > "$QUARANTINE_LOG"

ts_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

VALID_KINDS="ping|message|rfc|decision|announcement|ack|question|urgent|attachment|quarantine|thread-stub|task|task-result|bg-job|pipeline-step|heartbeat|dead-letter|delegate|delegate-result|hitl|hitl-result|event"

quarantine_file() {
    local f="$1" reason="$2" inbox_agent="$3"
    local base; base=$(basename "$f")
    local dest="${QUARANTINE_DIR}/${base}"
    [[ -f "$dest" ]] && dest="${QUARANTINE_DIR}/$(ts_iso | tr ':' '-')-${base}"
    mv "$f" "$dest"
    cat >> "$QUARANTINE_LOG" <<EOF

## $(ts_iso) — $base

- **From inbox:** $inbox_agent
- **Reason:** $reason
- **Moved to:** $dest
EOF
    log "QUARANTINE: $base — $reason"
}

audited=0
quarantined=0

for inbox in "${AGENTS_DIR}"/*/inbox; do
    inbox_agent=$(basename "$(dirname "$inbox")")
    for f in "${inbox}"/*.md; do
        [[ -f "$f" ]] || continue
        audited=$((audited + 1))
        base=$(basename "$f")

        frontmatter=$(python3 - "$f" <<'PYEOF'
import sys, re
content = open(sys.argv[1]).read()
m = re.match(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
if not m:
    print("NO_FRONTMATTER")
    sys.exit(0)
for line in m.group(1).splitlines():
    print(line)
PYEOF
)

        if [[ "$frontmatter" == "NO_FRONTMATTER" ]]; then
            quarantine_file "$f" "malformed: no frontmatter block" "$inbox_agent"
            quarantined=$((quarantined + 1)); continue
        fi

        author=$(echo "$frontmatter" | grep -m1 '^AUTHOR:' | sed 's/AUTHOR: *//' | tr -d '"' | xargs)
        kind=$(echo "$frontmatter" | grep -m1 '^KIND:' | sed 's/KIND: *//' | tr -d '"' | xargs)
        speaking_as=$(echo "$frontmatter" | grep -m1 '^SPEAKING_AS:' | sed 's/SPEAKING_AS: *//' | tr -d '"' | xargs || true)

        if [[ -z "$author" ]]; then
            quarantine_file "$f" "malformed: missing AUTHOR field" "$inbox_agent"
            quarantined=$((quarantined + 1)); continue
        fi
        if [[ -z "$kind" ]]; then
            quarantine_file "$f" "malformed: missing KIND field" "$inbox_agent"
            quarantined=$((quarantined + 1)); continue
        fi
        if ! echo "$kind" | grep -qE "^($VALID_KINDS)$"; then
            quarantine_file "$f" "invalid KIND: '$kind' not in §9 enum" "$inbox_agent"
            quarantined=$((quarantined + 1)); continue
        fi

        # SPEAKING_AS validation
        # Operator-identity values: no agent sent/ record exists — skip AUTHOR check.
        if [[ "$speaking_as" == "mike-direct" || "$speaking_as" == "operator-direct" ]]; then
            continue
        fi

        # Non-empty SPEAKING_AS: validate against explicit allowlist.
        # AUTHOR verification still runs below — SPEAKING_AS does NOT bypass it.
        if [[ -n "$speaking_as" ]]; then
            if [[ "$speaking_as" == "orchestrator-relay" ]]; then
                : # valid relay; AUTHOR check runs for the relaying agent
            elif [[ "$speaking_as" =~ ^[a-z0-9_-]+-on-behalf-of-[a-z0-9_-]+$ ]]; then
                # Validate the on-behalf-of target is a registered agent
                behalf_target="${speaking_as#*-on-behalf-of-}"
                if [[ ! -d "${AGENTS_DIR}/${behalf_target}" ]]; then
                    quarantine_file "$f" "invalid SPEAKING_AS: on-behalf-of target '${behalf_target}' has no agents/ slot" "$inbox_agent"
                    quarantined=$((quarantined + 1)); continue
                fi
                # AUTHOR check still runs for the acting agent below
            else
                quarantine_file "$f" "invalid SPEAKING_AS: '${speaking_as}' — allowed values: orchestrator-relay | <agent>-on-behalf-of-<agent>" "$inbox_agent"
                quarantined=$((quarantined + 1)); continue
            fi
        fi

        # AUTHOR vs sent/ verification
        author_agent="${author%@mesh}"
        sent_dir="${AGENTS_DIR}/${author_agent}/sent"
        if [[ ! -d "$sent_dir" ]]; then
            quarantine_file "$f" "unknown AUTHOR agent: '$author_agent' has no agents/ slot" "$inbox_agent"
            quarantined=$((quarantined + 1)); continue
        fi

        # Resolve sent_dir to its real path to block symlink-based bypass: an agent
        # writing a symlink inside its own sent/ that points outside its directory
        # cannot use it to forge another agent's authorship.
        sent_real=$(realpath -m "$sent_dir" 2>/dev/null || echo "$sent_dir")

        _sent_path_ok() {
            local candidate="$1"
            [[ -f "$candidate" ]] || return 1
            local real; real=$(realpath -m "$candidate" 2>/dev/null) || return 1
            [[ "$real" == "${sent_real}/"* ]] || [[ "$real" == "${sent_real}" ]]
        }

        date_prefix=$(echo "$base" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{3}' || true)
        sent_match=false
        if _sent_path_ok "${sent_dir}/${base}"; then
            sent_match=true
        elif [[ -n "$date_prefix" ]]; then
            for _candidate in "${sent_dir}/${date_prefix}-${author_agent}-"*.md; do
                if _sent_path_ok "$_candidate"; then
                    sent_match=true
                    break
                fi
            done
        fi

        if ! $sent_match; then
            quarantine_file "$f" "AUTHOR mismatch: '$author' has no matching file in agents/${author_agent}/sent/" "$inbox_agent"
            quarantined=$((quarantined + 1))
        fi
    done
done

log "Audit complete: $audited files checked, $quarantined quarantined"
