#!/usr/bin/env bash
# mesh-inotify.sh — Host-side inbox watchdog.
#
# Watches the host agent's inbox and the shared mesh/ directory for changes.
# Uses inotifywait if available, otherwise falls back to 5-second polling.
# Events are written to /var/log/filament-mesh.log.
#
# Run via systemd (filament-mesh.service) — mesh-init.sh installs it.

MESH_ROOT="${MESH_ROOT:-/opt/filament-mesh}"
HOST_INBOX="${MESH_ROOT}/agents/host/inbox"
MESH_DIR="${MESH_ROOT}/mesh"
LOG="/var/log/filament-mesh.log"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

write_log() {
    echo "$(ts) MESH-WATCH $*" >> "$LOG" 2>/dev/null || true
}

write_log "watchdog starting (MESH_ROOT=${MESH_ROOT})"

if command -v inotifywait >/dev/null 2>&1; then
    # inotify-driven (preferred)
    write_log "using inotifywait"
    inotifywait -m -r \
        -e create -e moved_to -e close_write \
        --format '%T %w %f %e' \
        --timefmt '%Y-%m-%dT%H:%M:%SZ' \
        "$HOST_INBOX" "$MESH_DIR" 2>/dev/null \
    | while read -r ts_ev path file event; do
        write_log "EVENT path=${path} file=${file} event=${event}"
    done
else
    # Poll fallback
    write_log "inotifywait not found — using 5s poll fallback"
    prev_count=0
    while true; do
        count=$(find "$HOST_INBOX" "$MESH_DIR" -maxdepth 2 -type f 2>/dev/null | wc -l)
        if [[ "$count" != "$prev_count" ]]; then
            write_log "POLL change detected (files: $prev_count → $count)"
            prev_count=$count
        fi
        sleep 5
    done
fi
