#!/usr/bin/env bash
# hitl-expire.sh — Expire timed-out HITL requests and deliver results.
# Run every 5 minutes via cron.
#
# Install via mesh-init.sh, or manually:
#   */5 * * * * MESH_ROOT=/opt/filament-mesh bash /path/to/scripts/hitl-expire.sh

set -euo pipefail

MESH_ROOT="${MESH_ROOT:-/opt/filament-mesh}"
HITL_ROOT="${MESH_ROOT}/hitl"
AGENTS_DIR="${MESH_ROOT}/agents"
NOW=$(date -u +%s)
DATE=$(date -u +%Y-%m-%d)

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
expired_count=0

for f in "${HITL_ROOT}/pending/"*.json; do
    [[ -f "$f" ]] || continue

    expires=$(python3 -c "
import json, sys
try:
    d = json.load(open('${f}'))
    print(d.get('expires') or '')
except:
    print('')
" 2>/dev/null)

    [[ -z "$expires" ]] && continue
    exp_epoch=$(date -u -d "$expires" +%s 2>/dev/null || echo 0)
    [[ "$exp_epoch" -le 0 ]] && continue
    [[ "$NOW" -lt "$exp_epoch" ]] && continue

    meta=$(python3 - "$f" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('id', 'unknown'))
    print(d.get('agent', ''))
    print(d.get('callback_to') or d.get('agent') or '')
    print(d.get('fallback', 'skip'))
except:
    print('unknown'); print(''); print(''); print('skip')
PYEOF
)
    req_id=$(echo "$meta" | sed -n '1p')
    sender=$(echo "$meta" | sed -n '2p')
    callback_to=$(echo "$meta" | sed -n '3p')
    fallback=$(echo "$meta" | sed -n '4p')

    log "EXPIRED: $req_id (from $sender, fallback=$fallback)"

    mv "$f" "${HITL_ROOT}/expired/$(basename "$f")"

    result_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "${HITL_ROOT}/resolved/${req_id}-result.json" <<JSONEOF
{
  "id": "$req_id",
  "resolved_at": "$result_ts",
  "resolution": "expired",
  "action": "$fallback",
  "notes": "Auto-expired by hitl-expire cron. Fallback action: $fallback."
}
JSONEOF

    callback_agent="${callback_to%@mesh}"
    inbox_path="${AGENTS_DIR}/${callback_agent}/inbox"
    if [[ -d "$inbox_path" ]]; then
        NNN=$(ls "${inbox_path}"/*.md 2>/dev/null | grep "^${inbox_path}/${DATE}-" | wc -l || echo 0)
        NNN=$(printf "%03d" $((NNN + 1)))
        cat > "${inbox_path}/${DATE}-${NNN}-host-hitl-result-expired-${req_id}.md" <<MSGEOF
---
KIND: hitl-result
AUTHOR: host@mesh
READERS: [${callback_to}]
REPLIES-TO: hitl-request-${req_id}
SIZE: short
END-OF-TURN: none
---
## HITL request expired: $req_id

- **Resolution:** expired
- **Action taken:** $fallback
- **Expired at:** $result_ts

No human response was received before the deadline. Fallback action \`$fallback\` applies.
MSGEOF
        log "  hitl-result delivered to $callback_to"
    else
        log "  WARN: callback agent inbox not found: $inbox_path"
    fi
    expired_count=$((expired_count + 1))
done

[[ "$expired_count" -gt 0 ]] && log "$expired_count item(s) expired" || true
