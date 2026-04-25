#!/usr/bin/env bash
# install.sh -- one-line installer for Filament.
#
# Designed for: curl -fsSL https://raw.githubusercontent.com/MCERQUA/filament/main/scripts/install.sh | sudo bash
#
# Idempotent. Safe to re-run. Walks the operator through every step with
# clear progress markers and a summary at the end.
#
# Configuration (env):
#   INSTALL_DIR    where filament + mesh live      (default: /opt)
#                  ->   $INSTALL_DIR/filament/repo  = source checkout
#                  ->   $INSTALL_DIR/filament-mesh  = mesh root
#   FILAMENT_REPO_URL                              (default: https://github.com/MCERQUA/filament.git)
#   FILAMENT_BRANCH                                (default: main)
#   MESH_USER      user that owns the mesh         (default: filament; created if missing)
#   BIN_DIR        where to install CLI shims      (default: /usr/local/bin)
#   SKIP_USER      "1" to skip user creation       (use existing $SUDO_USER)
#   SKIP_SYSTEMD   "1" to skip systemd watchdog install
#   SKIP_INIT      "1" to skip mesh-init.sh

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt}"
FILAMENT_REPO_URL="${FILAMENT_REPO_URL:-https://github.com/MCERQUA/filament.git}"
FILAMENT_BRANCH="${FILAMENT_BRANCH:-main}"
MESH_USER="${MESH_USER:-filament}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
SKIP_USER="${SKIP_USER:-0}"
SKIP_SYSTEMD="${SKIP_SYSTEMD:-0}"
SKIP_INIT="${SKIP_INIT:-0}"

REPO_DIR="${INSTALL_DIR}/filament/repo"
MESH_ROOT="${INSTALL_DIR}/filament-mesh"
LOG_DIR="/var/log/filament"

# Colors / markers (no emoji per project convention)
if [[ -t 1 ]]; then
    C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_B=$'\033[0;34m'; C_RESET=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_B=""; C_RESET=""
fi

step() { printf "\n%s>%s %s\n" "$C_B" "$C_RESET" "$1"; }
ok()   { printf "  %s+%s %s\n" "$C_G" "$C_RESET" "$1"; }
warn() { printf "  %s!%s %s\n" "$C_Y" "$C_RESET" "$1"; }
fail() { printf "  %sX%s %s\n" "$C_R" "$C_RESET" "$1" >&2; }
die()  { fail "$1"; exit 1; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "must run as root: curl ... | sudo bash  (or: sudo bash install.sh)"
    fi
}

# --- Step 1: detect distro + install dependencies ----------------------------
detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then echo apt
    elif command -v dnf >/dev/null 2>&1; then echo dnf
    elif command -v pacman >/dev/null 2>&1; then echo pacman
    else echo unknown; fi
}

install_deps() {
    local mgr
    mgr=$(detect_pkg_mgr)
    step "Installing required dependencies (mgr=${mgr})"

    case "$mgr" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                git python3 python3-yaml >/dev/null 2>&1 \
                && ok "git, python3, python3-yaml installed"
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
                inotify-tools >/dev/null 2>&1 \
                && ok "inotify-tools installed (recommended)" \
                || warn "inotify-tools not installed -- watchdog will use 5s polling"
            ;;
        dnf)
            dnf install -y -q git python3 python3-pyyaml >/dev/null \
                && ok "git, python3, python3-pyyaml installed"
            dnf install -y -q inotify-tools >/dev/null 2>&1 \
                && ok "inotify-tools installed (recommended)" \
                || warn "inotify-tools not installed -- watchdog will use 5s polling"
            ;;
        pacman)
            pacman -Sy --noconfirm git python python-yaml >/dev/null 2>&1 \
                && ok "git, python, python-yaml installed"
            pacman -S --noconfirm inotify-tools >/dev/null 2>&1 \
                && ok "inotify-tools installed (recommended)" \
                || warn "inotify-tools not installed -- watchdog will use 5s polling"
            ;;
        *)
            warn "unknown package manager -- ensure git + python3 are available"
            ;;
    esac

    # Verify python version (>= 3.8)
    if command -v python3 >/dev/null 2>&1; then
        local pv
        pv=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)'; then
            ok "python3 ${pv} >= 3.8"
        else
            die "python3 ${pv} too old -- need >= 3.8"
        fi
    else
        die "python3 not found and could not be installed"
    fi

    if ! command -v git >/dev/null 2>&1; then
        die "git not found and could not be installed"
    fi

    # Optional: Node 18+ for the MCP server
    if command -v node >/dev/null 2>&1; then
        local nv
        nv=$(node -v | sed 's/^v//;s/\..*//')
        if [[ "$nv" -ge 18 ]]; then
            ok "node $(node -v) >= 18 (MCP server installable)"
        else
            warn "node $(node -v) < 18 -- MCP server requires Node 18+"
        fi
    else
        warn "node not installed -- MCP server requires Node 18+ (optional)"
    fi
}

# --- Step 2: create mesh user ------------------------------------------------
ensure_user() {
    step "Ensuring mesh user '${MESH_USER}' exists"
    if [[ "$SKIP_USER" == "1" ]]; then
        warn "SKIP_USER=1 -- skipping user creation"
        return
    fi
    if id "$MESH_USER" >/dev/null 2>&1; then
        ok "user ${MESH_USER} already exists"
    else
        useradd --system --shell /bin/bash --create-home --home-dir "/var/lib/${MESH_USER}" "$MESH_USER" \
            && ok "created system user ${MESH_USER}"
    fi
}

# --- Step 3: clone or update repo --------------------------------------------
fetch_repo() {
    step "Fetching filament source"
    mkdir -p "$(dirname "$REPO_DIR")"
    if [[ -d "$REPO_DIR/.git" ]]; then
        ok "repo already at ${REPO_DIR} -- updating"
        git -C "$REPO_DIR" fetch --quiet origin "$FILAMENT_BRANCH"
        git -C "$REPO_DIR" checkout --quiet "$FILAMENT_BRANCH"
        git -C "$REPO_DIR" reset --hard --quiet "origin/${FILAMENT_BRANCH}"
    else
        rm -rf "$REPO_DIR"
        git clone --quiet --branch "$FILAMENT_BRANCH" "$FILAMENT_REPO_URL" "$REPO_DIR" \
            && ok "cloned ${FILAMENT_REPO_URL} -> ${REPO_DIR}"
    fi
    chown -R "${MESH_USER}:${MESH_USER}" "$(dirname "$REPO_DIR")"
}

# --- Step 4: log dir ---------------------------------------------------------
ensure_log_dir() {
    step "Preparing log directory ${LOG_DIR}"
    mkdir -p "$LOG_DIR"
    chown "${MESH_USER}:${MESH_USER}" "$LOG_DIR"
    chmod 750 "$LOG_DIR"
    ok "${LOG_DIR} ready"
}

# --- Step 5: run mesh-init ---------------------------------------------------
run_mesh_init() {
    step "Initializing mesh at ${MESH_ROOT}"
    if [[ "$SKIP_INIT" == "1" ]]; then
        warn "SKIP_INIT=1 -- skipping mesh-init.sh"
        return
    fi
    MESH_ROOT="$MESH_ROOT" MESH_USER="$MESH_USER" MESH_BIN="$BIN_DIR" \
        bash "${REPO_DIR}/scripts/mesh-init.sh"
    ok "mesh-init complete"
}

# --- Step 6: install operator scripts (symlink) ------------------------------
install_operator_scripts() {
    step "Installing operator scripts -> ${BIN_DIR}"
    # mesh-init already symlinks the bin/mesh-* CLIs. Add the operator scripts
    # too -- they're useful from the host shell.
    for script in mesh-patch-apply.sh mesh-blocker-check.sh; do
        local src="${REPO_DIR}/scripts/${script}"
        local dst="${BIN_DIR}/${script%.sh}"
        if [[ -f "$src" ]]; then
            ln -sf "$src" "$dst"
            ok "${dst} -> ${src}"
        fi
    done
}

# --- Step 7: print next steps ------------------------------------------------
print_summary() {
    cat <<EOF

${C_G}+${C_RESET} ${C_B}Filament installed${C_RESET}

  Source:      ${REPO_DIR}
  Mesh root:   ${MESH_ROOT}
  Log dir:     ${LOG_DIR}
  Mesh user:   ${MESH_USER}

${C_B}Next steps${C_RESET}

  1. Add your first agent (run as root, NOT as the mesh user):

       sudo MESH_ROOT=${MESH_ROOT} bash ${REPO_DIR}/scripts/agent-add.sh agent-a ${MESH_USER}
       sudo MESH_ROOT=${MESH_ROOT} bash ${REPO_DIR}/scripts/agent-add.sh agent-b ${MESH_USER}

  2. Send your first message:

       export AGENT_URI=agent-a@mesh
       export MESH_ROOT=${MESH_ROOT}
       echo 'hello mesh' | mesh-send --to agent-b@mesh --kind ping --subject hello

  3. Receive it:

       AGENT_URI=agent-b@mesh MESH_ROOT=${MESH_ROOT} mesh-recv

  4. Optional -- enable systemd timers (canvas dashboard, blocker sweep, etc.):

       sudo cp ${REPO_DIR}/systemd/filament-*.service \\
               ${REPO_DIR}/systemd/filament-*.timer /etc/systemd/system/
       sudo systemctl daemon-reload
       sudo systemctl enable --now filament-canvas-generator.timer

  5. Read the docs:

       ${REPO_DIR}/docs/QUICKSTART.md
       ${REPO_DIR}/docs/OPERATOR-GUIDE.md
       ${REPO_DIR}/PROTOCOL.md

EOF
}

# --- main --------------------------------------------------------------------
main() {
    require_root
    install_deps
    ensure_user
    fetch_repo
    ensure_log_dir
    run_mesh_init
    install_operator_scripts
    print_summary
}

main "$@"
