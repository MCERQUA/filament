#!/usr/bin/env bash
# mesh-rollover.sh — Daily 04:15 UTC cron.
#
# 1. Archives each agent's inbox files >24h old into sent/archive/YYYY-MM/
# 2. Regenerates mesh/THREADS.md (200-line rolling summary)
# 3. Git commits the mesh root (excluding */desk/)
#
# Install via mesh-init.sh, or manually:
#   15 4 * * * MESH_ROOT=/opt/filament-mesh bash /path/to/scripts/mesh-rollover.sh

set -eu

MESH_ROOT="${MESH_ROOT:-/opt/filament-mesh}"
AGENTS_DIR="${MESH_ROOT}/agents"
MESH_DIR="${MESH_ROOT}/mesh"
THREADS_DIR="${MESH_ROOT}/threads"

GIT_AUTHOR="${GIT_AUTHOR:-Filament}"
GIT_EMAIL="${GIT_EMAIL:-filament@localhost}"

LOG="/var/log/filament-mesh.log"
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
mlog() { printf '%s\tROLLOVER\t%s\n' "$(ts)" "$1" >> "$LOG" 2>/dev/null || true; }

mlog "start"
[[ -d "$AGENTS_DIR" ]] || { mlog "error: agents dir missing"; exit 1; }

month_slug=$(date -u +%Y-%m)
now_epoch=$(date +%s)
cutoff_epoch=$((now_epoch - 86400))
archived=0

# ── 1. Archive old inbox files ────────────────────────────────────────────────
for agent_dir in "$AGENTS_DIR"/*/; do
    [[ -d "$agent_dir" ]] || continue
    inbox="${agent_dir}inbox"
    archive="${agent_dir}sent/archive/${month_slug}"
    [[ -d "$inbox" ]] || continue
    mkdir -p "$archive"

    for src_dir in "$inbox" "$inbox/.read"; do
        [[ -d "$src_dir" ]] || continue
        while IFS= read -r -d '' f; do
            mtime=$(stat -c%Y "$f" 2>/dev/null || echo 0)
            if [[ "$mtime" -lt "$cutoff_epoch" ]]; then
                base=$(basename "$f")
                dest="${archive}/${base}"
                [[ -e "$dest" ]] && dest="${archive}/${base}.archived-$(date -u +%Y%m%d-%H%M%S)"
                mv "$f" "$dest"
                archived=$((archived + 1))
            fi
        done < <(find "$src_dir" -maxdepth 1 -type f -name '*.md' -print0 2>/dev/null)
    done
done
mlog "archived ${archived} stale inbox file(s)"

# ── 2. Regenerate THREADS.md ──────────────────────────────────────────────────
threads_md="${MESH_DIR}/THREADS.md"
tmp="${threads_md}.tmp.$$"
{
    echo "# THREADS.md — rolling summary (last 200 lines)"
    echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    if [[ -d "$THREADS_DIR" ]]; then
        ls -1dt "$THREADS_DIR"/*/ 2>/dev/null | head -50 | while read -r tdir; do
            slug=$(basename "$tdir")
            thread_md="${tdir}THREAD.md"
            if [[ -f "$thread_md" ]]; then
                echo "## ${slug}"
                head -20 "$thread_md" 2>/dev/null
                echo
            fi
        done
    else
        echo "(no threads/ dir yet)"
    fi
} | head -200 > "$tmp"
mv -f "$tmp" "$threads_md"
mlog "regenerated THREADS.md"

# ── 3. Git commit ─────────────────────────────────────────────────────────────
cd "$MESH_ROOT"
if [[ -d .git ]]; then
    git add -A 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
        GIT_AUTHOR_NAME="$GIT_AUTHOR" \
        GIT_AUTHOR_EMAIL="$GIT_EMAIL" \
        GIT_COMMITTER_NAME="$GIT_AUTHOR" \
        GIT_COMMITTER_EMAIL="$GIT_EMAIL" \
        git commit -m "rollover $(date -u +%Y-%m-%d) — archived=${archived}" >/dev/null 2>&1 || true
        mlog "git commit ok"
    else
        mlog "git: nothing to commit"
    fi
fi

mlog "done"
