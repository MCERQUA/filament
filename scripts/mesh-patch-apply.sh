#!/usr/bin/env bash
# mesh-patch-apply.sh — auto-apply KIND:patch messages from agent inboxes.
#
# Scans every agent's sent/ directory for KIND:patch messages, extracts the
# attached git format-patch, applies it to a local clone of the framework
# repo, pushes, and acks the author. Designed to run on a 5-minute timer.
#
# Robustness: NO errexit on per-message processing — failures don't abort
# the sweep. Three marker types: .applied / .skipped (non-patch) / .failed.
# Failed messages don't retry indefinitely (need manual intervention).
#
# Multi-commit patches where some commits are already on main: falls back
# to per-commit apply, skipping any whose subject matches a recent main commit.
#
# Configuration (all overridable via env):
#   MESH_ROOT         mesh root (default: /opt/filament-mesh)
#   FILAMENT_REPO     local clone to push patches into (default: /opt/filament/repo)
#   LOG_DIR           log directory (default: /var/log/filament)
#   STATE_DIR         marker storage for processed msgs (default: $LOG_DIR/patch-state)
#   MESH_SEND_BIN     full path to mesh-send (default: /usr/local/bin/mesh-send)
#   PATCH_BRANCH      branch to push patches to (default: main)
#   AGENT_GLOB        glob of agent sent/ dirs (default: $MESH_ROOT/agents/*/sent)

set -uo pipefail   # NO errexit — handle failures explicitly per-message

MESH_ROOT="${MESH_ROOT:-/opt/filament-mesh}"
FILAMENT_REPO="${FILAMENT_REPO:-/opt/filament/repo}"
LOG_DIR="${LOG_DIR:-/var/log/filament}"
STATE_DIR="${STATE_DIR:-${LOG_DIR}/patch-state}"
MESH_SEND_BIN="${MESH_SEND_BIN:-/usr/local/bin/mesh-send}"
PATCH_BRANCH="${PATCH_BRANCH:-main}"
AGENT_GLOB="${AGENT_GLOB:-${MESH_ROOT}/agents/*/sent}"

LOG="${LOG_DIR}/mesh-patch-apply.log"
mkdir -p "$STATE_DIR" "$LOG_DIR"

log() { echo "$(date -uIs) $*" >> "$LOG"; }

if [[ ! -d "$FILAMENT_REPO/.git" ]]; then
    log "FATAL: $FILAMENT_REPO is not a git repo — set FILAMENT_REPO env"
    exit 1
fi

cd "$FILAMENT_REPO" || { log "FATAL: cannot cd to $FILAMENT_REPO"; exit 1; }
git fetch origin >/dev/null 2>&1
git checkout "$PATCH_BRANCH" >/dev/null 2>&1
git reset --hard "origin/${PATCH_BRANCH}" >/dev/null 2>&1

PROCESSED=0
APPLIED=0
SKIPPED_KIND=0
FAILED=0

# Expand the glob (word-splitting is intentional so AGENT_GLOB can contain "a b c")
# shellcheck disable=SC2086
for sent_dir in $AGENT_GLOB; do
    [[ -d "$sent_dir" ]] || continue
    agent="$(basename "$(dirname "$sent_dir")")"

    for msg in "$sent_dir"/*.md; do
        [[ -f "$msg" ]] || continue
        msg_base=$(basename "$msg")
        applied_marker="$STATE_DIR/.applied.$msg_base"
        failed_marker="$STATE_DIR/.failed.$msg_base"
        skipped_marker="$STATE_DIR/.skipped.$msg_base"

        # Already processed?
        [[ -f "$applied_marker" || -f "$failed_marker" || -f "$skipped_marker" ]] && continue

        PROCESSED=$((PROCESSED + 1))

        # Quick KIND:patch check — anything else gets the .skipped marker
        if ! head -10 "$msg" | grep -q "^KIND: patch"; then
            touch "$skipped_marker"
            SKIPPED_KIND=$((SKIPPED_KIND + 1))
            continue
        fi

        log "[${agent}] processing $msg_base"

        # Extract patch body (everything after first "From <sha>" or "diff --git")
        patch_file="$STATE_DIR/$msg_base.patch"
        awk '/^From [0-9a-f]{40}|^diff --git/{p=1} p' "$msg" > "$patch_file"

        if [[ ! -s "$patch_file" ]]; then
            log "  ! no patch content found, marking failed"
            touch "$failed_marker"
            FAILED=$((FAILED + 1))
            continue
        fi

        # Try git am --3way first
        if git am --3way "$patch_file" >> "$LOG" 2>&1; then
            log "  + git am --3way succeeded"
            APPLIED=$((APPLIED + 1))
        else
            git am --abort 2>/dev/null || true
            git checkout "$PATCH_BRANCH" >/dev/null 2>&1
            git reset --hard "origin/${PATCH_BRANCH}" >/dev/null 2>&1

            # Fallback: split + skip-already-merged
            log "  -> fallback: split + skip-already-merged"
            split_dir="$STATE_DIR/.split.$msg_base.d"
            rm -rf "$split_dir" && mkdir -p "$split_dir"
            ( cd "$split_dir" && csplit -z -f part- -b "%02d.patch" "$patch_file" '/^From [0-9a-f]\{40\}/' '{*}' >/dev/null 2>&1 )

            partial_applied=0
            for part in "$split_dir"/part-*.patch; do
                [[ -s "$part" ]] || continue
                subj=$(grep -m1 "^Subject:" "$part" | sed 's/^Subject: \[PATCH [0-9]*\/[0-9]*\] *//')
                # Skip if a commit with the same subject is already on origin/$PATCH_BRANCH
                if git log --pretty=%s "origin/${PATCH_BRANCH}" -50 | grep -qF "$subj"; then
                    log "    skip (already on ${PATCH_BRANCH}): $subj"
                    continue
                fi
                if git am --3way "$part" >> "$LOG" 2>&1; then
                    log "    + applied: $subj"
                    partial_applied=$((partial_applied + 1))
                else
                    log "    ! failed: $subj"
                    git am --abort 2>/dev/null || true
                fi
            done

            if [[ $partial_applied -eq 0 ]]; then
                log "  ! no commits applied — marking failed"
                touch "$failed_marker"
                FAILED=$((FAILED + 1))
                continue
            fi
            APPLIED=$((APPLIED + 1))
        fi

        # Push
        if git push origin "$PATCH_BRANCH" >> "$LOG" 2>&1; then
            new_sha=$(git rev-parse HEAD)
            log "  + pushed: ${new_sha:0:8}"

            # Ack to author (short body, fits 200B cap)
            if [[ -x "$MESH_SEND_BIN" ]]; then
                AGENT_URI="host@mesh" MESH_ROOT="$MESH_ROOT" "$MESH_SEND_BIN" \
                    --to "${agent}@mesh" --kind ack \
                    --subject "auto-applied: ${msg_base:0:50}" \
                    <<<"Pushed: ${new_sha:0:8}" >> "$LOG" 2>&1 || true
            fi
            touch "$applied_marker"
        else
            log "  ! push failed — marking failed"
            touch "$failed_marker"
            FAILED=$((FAILED + 1))
        fi
    done
done

log "sweep: processed=$PROCESSED  applied=$APPLIED  skipped(non-patch)=$SKIPPED_KIND  failed=$FAILED"
