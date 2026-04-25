#!/usr/bin/env bash
# Sibling to mesh-heartbeat-check.sh — monitors host inbox for stale unread messages.
# Emits a STATE_CHECK alert when the oldest unread file exceeds the active/overnight threshold.
#
# Env vars (all optional):
#   HOST_INBOX_STALE_MIN_DAY   — active-hours threshold in minutes (default: 60)
#   HOST_INBOX_STALE_MIN_NIGHT — overnight threshold in minutes    (default: 240)
#   ACTIVE_HOURS_START         — UTC hour when active hours begin  (default: 8)
#   ACTIVE_HOURS_END           — UTC hour when active hours end    (default: 22)
#   AGENT_MESH_ROOT            — mesh root dir                     (default: /opt/filament-mesh)
#   HITL_PENDING_DIR           — if set, also write a HITL card    (optional)

set -euo pipefail

MESH_ROOT="${AGENT_MESH_ROOT:-/opt/filament-mesh}"
HOST_INBOX="${MESH_ROOT}/agents/host/inbox"
STATE_CHECK_DIR="${MESH_ROOT}/mesh/STATE_CHECK"

HOST_INBOX_STALE_MIN_DAY="${HOST_INBOX_STALE_MIN_DAY:-60}"
HOST_INBOX_STALE_MIN_NIGHT="${HOST_INBOX_STALE_MIN_NIGHT:-240}"
ACTIVE_HOURS_START="${ACTIVE_HOURS_START:-8}"
ACTIVE_HOURS_END="${ACTIVE_HOURS_END:-22}"
HITL_PENDING_DIR="${HITL_PENDING_DIR:-}"

# Determine active vs overnight threshold
current_hour=$(date -u +%-H)
if [ "$current_hour" -ge "$ACTIVE_HOURS_START" ] && [ "$current_hour" -lt "$ACTIVE_HOURS_END" ]; then
    threshold_min="$HOST_INBOX_STALE_MIN_DAY"
    hours_label="active-hours"
else
    threshold_min="$HOST_INBOX_STALE_MIN_NIGHT"
    hours_label="overnight"
fi

# Walk top-level unread .md files (exclude .read/ subdir)
oldest_mtime=""
oldest_file=""
unread_count=0

while IFS= read -r -d '' f; do
    unread_count=$(( unread_count + 1 ))
    mtime=$(timeout 5 stat -c %Y "$f" 2>/dev/null) || continue
    if [ -z "$oldest_mtime" ] || [ "$mtime" -lt "$oldest_mtime" ]; then
        oldest_mtime="$mtime"
        oldest_file="$f"
    fi
done < <(find "$HOST_INBOX" -maxdepth 1 -name '*.md' -print0 2>/dev/null)

# No unread files — host inbox clear
[ -z "$oldest_file" ] && exit 0

now=$(date +%s)
age_sec=$(( now - oldest_mtime ))
age_min=$(( age_sec / 60 ))
threshold_sec=$(( threshold_min * 60 ))

[ "$age_sec" -le "$threshold_sec" ] && exit 0

# Threshold exceeded — emit STATE_CHECK alert
ts=$(date -u +%Y-%m-%dT%H%M%SZ)
oldest_basename=$(basename "$oldest_file")
alert_file="${STATE_CHECK_DIR}/${ts}-host-inbox-stale-${age_min}m.md"

cat > "$alert_file" <<EOF
## host@mesh @ ${ts}
- event: host-inbox-stale
- detail: oldest unread message ${age_min}m old (threshold: ${threshold_min}m, ${hours_label})
- unread_count: ${unread_count}
- oldest_file: ${oldest_basename}
EOF

# Append unread list sorted oldest-first
echo "" >> "$alert_file"
echo "### Unread files (oldest first)" >> "$alert_file"
timeout 10 find "$HOST_INBOX" -maxdepth 1 -name '*.md' -printf '%T@ %f\n' 2>/dev/null \
    | sort -n \
    | awk '{print "- " $2}' \
    >> "$alert_file"

echo "[mesh-host-inbox-staleness-check] ALERT: host inbox ${age_min}m stale (threshold ${threshold_min}m, ${hours_label}). ${unread_count} unread. Alert: $(basename "$alert_file")" >&2

# Optional HITL card — surface blocked items to Mike
if [ -n "$HITL_PENDING_DIR" ] && [ -d "$HITL_PENDING_DIR" ]; then
    hitl_file="${HITL_PENDING_DIR}/${ts}-host-inbox-stale-hitl.json"
    hitl_unread_list=$(timeout 10 find "$HOST_INBOX" -maxdepth 1 -name '*.md' -printf '"%f",' 2>/dev/null \
        | sed 's/,$//' )
    cat > "$hitl_file" <<EOF
{
  "kind": "hitl",
  "agent": "host@mesh",
  "created_at": "${ts}",
  "subject": "host inbox stale ${age_min}m — ${unread_count} unread message(s)",
  "body": "Host inbox has ${unread_count} unread message(s). Oldest is ${age_min} minutes old (threshold: ${threshold_min}m, ${hours_label}). Oldest: ${oldest_basename}",
  "unread_files": [${hitl_unread_list}],
  "state_check_alert": "$(basename "$alert_file")"
}
EOF
fi
