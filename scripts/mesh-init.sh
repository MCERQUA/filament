#!/usr/bin/env bash
# mesh-init.sh — One-shot host-side bring-up of a Filament agent mesh.
#
# Creates the MESH_ROOT directory tree, writes static files (PROTOCOL.md,
# QUARANTINE-PLAYBOOK.md, REGISTRY/host.md), initialises git, installs the
# host systemd watchdog, and installs cron entries for rollover + rollup.
#
# Idempotent — safe to re-run. Existing files that would change are backed
# up as <file>.bak-<ts> before overwrite.
#
# USAGE:
#   sudo bash scripts/mesh-init.sh
#
# CONFIGURATION (override via env vars):
#   MESH_ROOT    — where the mesh lives (default: /opt/filament-mesh)
#   MESH_USER    — user that owns the mesh (default: current user)
#   MESH_BIN     — where CLIs are installed (default: /usr/local/bin)
#   GIT_AUTHOR   — author name for git commits (default: Filament)
#   GIT_EMAIL    — author email for git commits (default: filament@localhost)

set -eu

MESH_ROOT="${MESH_ROOT:-/opt/filament-mesh}"
MESH_USER="${MESH_USER:-${SUDO_USER:-$(whoami)}}"
MESH_BIN="${MESH_BIN:-/usr/local/bin}"
GIT_AUTHOR="${GIT_AUTHOR:-Filament}"
GIT_EMAIL="${GIT_EMAIL:-filament@localhost}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BIN_SRC="${REPO_ROOT}/bin"
STATIC_SRC="${REPO_ROOT}/static"

MESH_DIR="${MESH_ROOT}/mesh"
AGENTS_DIR="${MESH_ROOT}/agents"
THREADS_DIR="${MESH_ROOT}/threads"
HOST_AGENT_DIR="${AGENTS_DIR}/host"

SYSTEMD_UNIT_DEST="/etc/systemd/system/filament-mesh.service"
WATCHDOG_LOG="/var/log/filament-mesh.log"
CRON_LOG="/var/log/filament-mesh-cron.log"

CRON_MARKER_ROLLOVER="# filament-mesh-rollover"
CRON_MARKER_ROLLUP="# filament-mesh-rollup"

TS="$(date +%Y%m%d-%H%M%S)"

step() { echo; echo "=== [$1] $2"; }
info() { echo "    -> $*"; }
warn() { echo "    !! $*"; }
die()  { echo "    XX $*" >&2; exit 1; }

backup_if_exists() {
    local f="$1"
    if [[ -e "$f" ]]; then
        cp -a "$f" "${f}.bak-${TS}"
        info "backup: ${f} -> ${f}.bak-${TS}"
    fi
}

ensure_dir() {
    local d="$1"; local mode="${2:-755}"; local owner="${3:-${MESH_USER}:${MESH_USER}}"
    mkdir -p "$d"
    chmod "$mode" "$d"
    chown "$owner" "$d"
}

write_if_changed() {
    local src="$1" dest="$2" owner="${3:-${MESH_USER}:${MESH_USER}}" mode="${4:-644}"
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        info "unchanged: $dest"
        return 0
    fi
    backup_if_exists "$dest"
    install -m "$mode" -o "${owner%:*}" -g "${owner#*:}" "$src" "$dest"
    info "installed: $dest"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
step "0" "Pre-flight"

if [[ $EUID -ne 0 ]]; then
    die "run as root: sudo bash scripts/mesh-init.sh"
fi

if ! id "$MESH_USER" >/dev/null 2>&1; then
    die "MESH_USER '${MESH_USER}' does not exist — set MESH_USER env var"
fi

MESH_UID=$(id -u "$MESH_USER")
MESH_GID=$(id -g "$MESH_USER")

if [[ -e "$MESH_ROOT" && ! -d "$MESH_ROOT" ]]; then
    die "$MESH_ROOT exists but is not a directory"
fi

if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not found — skipping systemd service install"
    SKIP_SYSTEMD=true
else
    SKIP_SYSTEMD=false
fi

if ! command -v inotifywait >/dev/null 2>&1; then
    warn "inotifywait not on PATH — watchdog will use 5s-poll fallback"
    warn "For kernel-driven monitoring: sudo apt install inotify-tools"
fi

info "MESH_ROOT=${MESH_ROOT}  MESH_USER=${MESH_USER}  BIN=${MESH_BIN}"

# ── Step 1: Directory tree ────────────────────────────────────────────────────
step "1" "Create directory tree at ${MESH_ROOT}"

ensure_dir "$MESH_ROOT"                          755
ensure_dir "$MESH_DIR"                           755
ensure_dir "${MESH_DIR}/REGISTRY"                755
ensure_dir "${MESH_DIR}/STATE_CHECK"             1777
ensure_dir "${MESH_DIR}/QUARANTINE"              755
ensure_dir "${MESH_DIR}/BROADCAST"               1777
ensure_dir "${MESH_DIR}/cc"                      755
ensure_dir "${MESH_DIR}/cc/host"                 1777
ensure_dir "${MESH_DIR}/DECISIONS"               755
ensure_dir "${MESH_DIR}/QUEUE"                   755
ensure_dir "${MESH_DIR}/BLACKBOARD"              755
ensure_dir "${MESH_DIR}/JOBS"                    755
ensure_dir "${MESH_DIR}/JOBS/active"             755
ensure_dir "${MESH_DIR}/JOBS/archive"            755
ensure_dir "${MESH_DIR}/JOBS/failed"             755
ensure_dir "${MESH_DIR}/HEARTBEAT"               755
ensure_dir "${MESH_DIR}/DEAD_LETTER"             755
ensure_dir "${MESH_DIR}/SEMAPHORES"              755
ensure_dir "${MESH_DIR}/PIPELINES"               755
ensure_dir "${MESH_DIR}/EVENTS"                  755
ensure_dir "${MESH_DIR}/SEED"                    700 "root:root"

ensure_dir "$AGENTS_DIR"                         755
ensure_dir "$HOST_AGENT_DIR"                     755
ensure_dir "${HOST_AGENT_DIR}/inbox"             1733
ensure_dir "${HOST_AGENT_DIR}/sent"              755
ensure_dir "${HOST_AGENT_DIR}/snapshots"         755
ensure_dir "${HOST_AGENT_DIR}/desk"              700

chown "${MESH_USER}:${MESH_USER}" \
    "${HOST_AGENT_DIR}/sent" \
    "${HOST_AGENT_DIR}/snapshots" \
    "${HOST_AGENT_DIR}/desk"

ensure_dir "$THREADS_DIR"  755
mkdir -p "${MESH_ROOT}/hitl/pending" "${MESH_ROOT}/hitl/resolved" "${MESH_ROOT}/hitl/expired"
chmod 1777 "${MESH_ROOT}/hitl/pending"
chown -R "${MESH_USER}:${MESH_USER}" "${MESH_ROOT}/hitl"

info "directory tree ready"

# ── Step 2: Static files ──────────────────────────────────────────────────────
step "2" "Write static files"

write_if_changed "${STATIC_SRC}/QUARANTINE-PLAYBOOK.md" \
    "${MESH_DIR}/QUARANTINE-PLAYBOOK.md" "${MESH_USER}:${MESH_USER}" 644
write_if_changed "${REPO_ROOT}/PROTOCOL.md" \
    "${MESH_DIR}/PROTOCOL.md" "${MESH_USER}:${MESH_USER}" 644

for placeholder in REGISTRY.md STATE_CHECK.md THREADS.md; do
    p="${MESH_DIR}/${placeholder}"
    if [[ ! -f "$p" ]]; then
        printf '# %s\n# Regenerated by mesh-rollup.sh (5-min cron) / mesh-rollover.sh (daily).\n\n(awaiting first rollup)\n' \
            "$placeholder" > "$p"
        chown "${MESH_USER}:${MESH_USER}" "$p"
        info "placeholder: $p"
    fi
done

if [[ ! -f "${MESH_DIR}/QUARANTINE/log.md" ]]; then
    printf '# Quarantine audit log\n# Format: <iso-ts>  <action>  <filename>  <reason>  <actor>\n# Append-only.\n\n' \
        > "${MESH_DIR}/QUARANTINE/log.md"
    chown "${MESH_USER}:${MESH_USER}" "${MESH_DIR}/QUARANTINE/log.md"
fi

# Host registry placeholder row
if [[ ! -f "${MESH_DIR}/REGISTRY/host.md" ]]; then
    cat > "${MESH_DIR}/REGISTRY/host.md" <<EOF
---
name: host
uri: host@mesh
node-class: host
capabilities: [orchestration, provisioning, cron-maintenance]
joined: $(date -u +%Y-%m-%d)
---

# host@mesh

The host VPS agent. Runs as ${MESH_USER}. Has direct filesystem access to all agent directories.
EOF
    chown "${MESH_USER}:${MESH_USER}" "${MESH_DIR}/REGISTRY/host.md"
    info "wrote REGISTRY/host.md"
fi

if [[ ! -f "${HOST_AGENT_DIR}/sent/RECENT.md" ]]; then
    printf '# RECENT.md — auto-tail of recent outgoing\n# Agent: host@mesh\n# Provisioned: %s\n\n(empty — mesh initialised, no traffic yet)\n' \
        "$TS" > "${HOST_AGENT_DIR}/sent/RECENT.md"
    chown "${MESH_USER}:${MESH_USER}" "${HOST_AGENT_DIR}/sent/RECENT.md"
fi

# ── Step 3: git init ──────────────────────────────────────────────────────────
step "3" "git init ${MESH_ROOT}"

GITIGNORE="${MESH_ROOT}/.gitignore"
if [[ ! -f "$GITIGNORE" ]]; then
    cat > "$GITIGNORE" <<'EOF'
*/desk/
agents/*/desk/
*.claim/
*.tmp.*
*.bak-*
EOF
    chown "${MESH_USER}:${MESH_USER}" "$GITIGNORE"
fi

if [[ ! -d "${MESH_ROOT}/.git" ]]; then
    su - "$MESH_USER" -c "
        cd ${MESH_ROOT} && git init -q && git add -A &&
        GIT_AUTHOR_NAME='${GIT_AUTHOR}' GIT_AUTHOR_EMAIL='${GIT_EMAIL}'
        GIT_COMMITTER_NAME='${GIT_AUTHOR}' GIT_COMMITTER_EMAIL='${GIT_EMAIL}'
        git commit -q -m 'mesh init ${TS}'
    "
    info "git repo initialised at ${MESH_ROOT}"
else
    info "git repo already exists"
fi

# ── Step 4: Install CLI tools ─────────────────────────────────────────────────
step "4" "Install CLI tools to ${MESH_BIN}"

for cli in mesh-send mesh-recv mesh-ack mesh-on mesh-task-claim mesh-jobs \
           mesh-pipeline mesh-event mesh-semaphore mesh-pick-residential; do
    src="${BIN_SRC}/${cli}"
    dest="${MESH_BIN}/${cli}"
    [[ -f "$src" ]] || { warn "bin not found: $src (skipping)"; continue; }
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
        info "unchanged: $dest"
        continue
    fi
    backup_if_exists "$dest"
    install -m 755 -o root -g root "$src" "$dest"
    info "installed: $dest"
done

chmod +x "${SCRIPT_DIR}"/*.sh

# ── Step 5: systemd service ───────────────────────────────────────────────────
step "5" "Install filament-mesh.service"

if [[ "$SKIP_SYSTEMD" == "false" ]]; then
    SERVICE_SRC="${REPO_ROOT}/systemd/filament-mesh.service"
    if [[ -f "$SERVICE_SRC" ]]; then
        # Substitute MESH_USER and MESH_ROOT in service file
        TMP_SERVICE=$(mktemp)
        sed -e "s|__MESH_USER__|${MESH_USER}|g" \
            -e "s|__MESH_ROOT__|${MESH_ROOT}|g" \
            -e "s|__SCRIPT_DIR__|${SCRIPT_DIR}|g" \
            "$SERVICE_SRC" > "$TMP_SERVICE"

        if [[ -f "$SYSTEMD_UNIT_DEST" ]] && cmp -s "$TMP_SERVICE" "$SYSTEMD_UNIT_DEST"; then
            info "service unchanged"
        else
            backup_if_exists "$SYSTEMD_UNIT_DEST"
            install -m 644 -o root -g root "$TMP_SERVICE" "$SYSTEMD_UNIT_DEST"
            info "installed: $SYSTEMD_UNIT_DEST"
        fi
        rm -f "$TMP_SERVICE"

        if [[ ! -f "$WATCHDOG_LOG" ]]; then touch "$WATCHDOG_LOG"; fi
        chown "${MESH_USER}:${MESH_USER}" "$WATCHDOG_LOG"
        chmod 640 "$WATCHDOG_LOG"

        systemctl daemon-reload
        systemctl enable filament-mesh.service
        systemctl restart filament-mesh.service && info "service started" || warn "service failed to start — check: journalctl -u filament-mesh"
    else
        warn "systemd/filament-mesh.service not found — skipping"
    fi
fi

# ── Step 6: Cron entries ──────────────────────────────────────────────────────
step "6" "Install cron entries for user '${MESH_USER}'"

CRON_TMP=$(mktemp)
crontab -u "$MESH_USER" -l 2>/dev/null > "$CRON_TMP" || :
grep -v -F "$CRON_MARKER_ROLLOVER" "$CRON_TMP" > "${CRON_TMP}.a" || true; mv "${CRON_TMP}.a" "$CRON_TMP"
grep -v -F "$CRON_MARKER_ROLLUP"   "$CRON_TMP" > "${CRON_TMP}.b" || true; mv "${CRON_TMP}.b" "$CRON_TMP"

cat >> "$CRON_TMP" <<EOF
${CRON_MARKER_ROLLOVER}
15 4 * * * MESH_ROOT=${MESH_ROOT} bash ${SCRIPT_DIR}/mesh-rollover.sh >> ${CRON_LOG} 2>&1
${CRON_MARKER_ROLLUP}
*/5 * * * * MESH_ROOT=${MESH_ROOT} bash ${SCRIPT_DIR}/mesh-rollup.sh >> ${CRON_LOG} 2>&1
EOF

crontab -u "$MESH_USER" "$CRON_TMP"
rm -f "$CRON_TMP"

if [[ ! -f "$CRON_LOG" ]]; then touch "$CRON_LOG"; fi
chown "${MESH_USER}:${MESH_USER}" "$CRON_LOG"
chmod 640 "$CRON_LOG"

# Run rollup immediately
su - "$MESH_USER" -c "MESH_ROOT=${MESH_ROOT} bash ${SCRIPT_DIR}/mesh-rollup.sh" >/dev/null 2>&1 || true
info "initial rollup complete"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== DONE"
echo
echo "  Mesh root:   ${MESH_ROOT}"
echo "  Protocol:    ${MESH_DIR}/PROTOCOL.md"
echo "  Host inbox:  ${HOST_AGENT_DIR}/inbox/"
echo "  Watchdog:    ${WATCHDOG_LOG}"
echo "  Cron:        rollover 04:15 daily, rollup every 5 min (user: ${MESH_USER})"
echo
echo "Self-test (run as ${MESH_USER}):"
echo "  AGENT_URI=host@mesh MESH_ROOT=${MESH_ROOT} mesh-on"
echo "  echo hello | AGENT_URI=host@mesh MESH_ROOT=${MESH_ROOT} mesh-send --to host@mesh --kind ping --subject self-test"
echo "  AGENT_URI=host@mesh MESH_ROOT=${MESH_ROOT} mesh-recv"
echo
echo "Add an agent:"
echo "  sudo bash scripts/agent-add.sh <agent-name> <owner>"
