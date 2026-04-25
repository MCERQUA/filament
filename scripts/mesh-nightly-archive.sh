#!/usr/bin/env bash
# mesh-nightly-archive.sh — 04:05 UTC cron: append nightly synthesis to THREADS rollup.
#
# Reads mesh/BLACKBOARD/nightly-reflections/<date>/group.md (written at 04:00Z by
# mesh-nightly-synthesize.sh) and appends to mesh/THREADS/nightly-reflections/<date>.md.
# The THREADS/ copy is the durable audit record; BLACKBOARD is working state.
#
# Idempotent: if the THREADS archive already exists and matches group.md, noop.
# Re-runs are safe.

set -euo pipefail

MESH_ROOT="${MESH_ROOT:-/opt/filament-mesh}"

LOG="${MESH_ROOT}/logs/mesh-nightly-archive.log"
mkdir -p "$(dirname "$LOG")"
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOG"; }

DATE="${1:-$(date -u +%Y-%m-%d)}"
SRC="${MESH_ROOT}/mesh/BLACKBOARD/nightly-reflections/${DATE}/group.md"
DST_DIR="${MESH_ROOT}/mesh/THREADS/nightly-reflections"
DST="${DST_DIR}/${DATE}.md"

if [[ ! -f "$SRC" ]]; then
    log "no source group.md at ${SRC}; nothing to archive"
    exit 0
fi

mkdir -p "$DST_DIR"

# Idempotency — skip if content is unchanged
if [[ -f "$DST" ]] && cmp -s "$SRC" "$DST"; then
    log "archive already up to date for ${DATE}"
    exit 0
fi

# Atomic copy via tmp+rename
tmp="${DST}.tmp"
cp "$SRC" "$tmp"
mv "$tmp" "$DST"

log "archived ${DATE} → ${DST}"
