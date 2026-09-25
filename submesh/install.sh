#!/bin/bash
# submesh/install.sh — installs the Filament sub-mesh agent system
# onto any ubuntu-os desktop container (KDE Plasma + Claude Code).
# Idempotent — safe to re-run to update commands, templates, or the icon.
#
# Usage:
#   bash submesh/install.sh <config-dir>
#
# Examples:
#   bash submesh/install.sh /srv/tenants/desk-a/config
#   bash submesh/install.sh /srv/tenants/desk-b/config
#
# <config-dir> is the HOST path of the directory the container sees as SUBMESH_HOME
# (default /config — the webtop convention). Set SUBMESH_HOME if your container mounts
# it elsewhere; it is baked into the desktop entry and the .bashrc PATH line.
#
# What it installs:
#   - All submesh commands + hook scripts → <config-dir>/mesh-tools/bin/
#       incl. desk-prefix.sh (the ONE desk-identity resolver every tool sources) and
#       render-guard.py (blocking PreToolUse hook: no video renders on this node)
#   - 5 agent role templates → <config-dir>/submesh-templates/
#   - Manager workspace scaffolding → <config-dir>/submesh/agents/manager/
#   - Custom 4-terminal grid SVG icon → <config-dir>/.local/share/icons/
#   - KDE desktop icon → <config-dir>/Desktop/submesh.desktop
#   - KDE app launcher entry → <config-dir>/.local/share/applications/
#   - tmux config (mouse, colors) → <config-dir>/mesh-tools/tmux.conf
#   - PATH fix in <config-dir>/.bashrc

set -euo pipefail

CONFIG_DIR="${1:-}"
if [ -z "$CONFIG_DIR" ]; then
    echo "Usage: $0 <config-dir>"
    echo "  e.g. $0 /srv/tenants/desk-a/config"
    exit 1
fi

if [ ! -d "$CONFIG_DIR" ]; then
    echo "ERROR: $CONFIG_DIR does not exist"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$CONFIG_DIR/mesh-tools/bin"
TEMPLATE_DIR="$CONFIG_DIR/submesh-templates"
ICON_DIR="$CONFIG_DIR/.local/share/icons"
APP_DIR="$CONFIG_DIR/.local/share/applications"
DESKTOP_DIR="$CONFIG_DIR/Desktop"
SUBMESH_DIR="$CONFIG_DIR/submesh"
# In-container path of <config-dir> (what the agents themselves see).
SUBMESH_HOME="${SUBMESH_HOME:-/config}"

echo "Installing Filament sub-mesh to: $CONFIG_DIR"

# ── Directories ────────────────────────────────────────────────────────────────
mkdir -p "$BIN_DIR" "$TEMPLATE_DIR" "$ICON_DIR" "$APP_DIR" "$DESKTOP_DIR"
mkdir -p "$SUBMESH_DIR/agents/manager/workspace"
mkdir -p "$SUBMESH_DIR/agents/manager/memory"

# ── Commands + hooks ───────────────────────────────────────────────────────────
echo "  → Installing commands..."
for f in "$SCRIPT_DIR/bin/"*; do
    [ -f "$f" ] || continue   # skip __pycache__ and other dirs (cp of a dir aborts under set -e)
    cp "$f" "$BIN_DIR/"
    chmod +x "$BIN_DIR/$(basename "$f")" 2>/dev/null || true
done

# ── tmux config ────────────────────────────────────────────────────────────────
echo "  → Installing tmux config..."
cp "$SCRIPT_DIR/assets/tmux.conf" "$CONFIG_DIR/mesh-tools/tmux.conf"

# ── Templates ──────────────────────────────────────────────────────────────────
echo "  → Installing agent role templates..."
cp "$SCRIPT_DIR/templates/"*.md "$TEMPLATE_DIR/"

# ── Icon ───────────────────────────────────────────────────────────────────────
echo "  → Installing icon..."
cp "$SCRIPT_DIR/assets/submesh.svg" "$ICON_DIR/submesh.svg"

# ── Desktop entry ──────────────────────────────────────────────────────────────
echo "  → Installing desktop entry..."
cat > "$DESKTOP_DIR/submesh.desktop" << DESKTOP
[Desktop Entry]
Type=Application
Name=Sub-Mesh
GenericName=Agent Sub-Mesh
Comment=Open the collaborative agent terminal grid
Exec=${SUBMESH_HOME}/mesh-tools/bin/submesh-launch
Icon=${SUBMESH_HOME}/.local/share/icons/submesh.svg
Categories=Development;
Keywords=mesh;agents;claude;submesh;filament;
StartupNotify=false
DESKTOP
chmod +x "$DESKTOP_DIR/submesh.desktop"
cp "$DESKTOP_DIR/submesh.desktop" "$APP_DIR/submesh.desktop"

# ── PATH fix ───────────────────────────────────────────────────────────────────
BASHRC="$CONFIG_DIR/.bashrc"
if [ -f "$BASHRC" ] && ! grep -q "mesh-tools/bin" "$BASHRC"; then
    echo "  → Adding mesh-tools/bin to PATH in .bashrc..."
    printf 'case ":$PATH:" in *":%s/mesh-tools/bin:"*) ;; *) export PATH="%s/mesh-tools/bin:$PATH" ;; esac\n' \
        "$SUBMESH_HOME" "$SUBMESH_HOME" >> "$BASHRC"
fi

# ── Slots state file ───────────────────────────────────────────────────────────
touch "$SUBMESH_DIR/slots"

echo ""
echo "✓ Sub-mesh installed at $CONFIG_DIR"
echo ""
echo "Commands now available in mesh-tools/bin:"
echo "  submesh-launch    open the 2x2 agent grid in Konsole"
echo "  new-agent         create and start a new agent in an empty slot"
echo "  submesh-agents    list all agents and their slot assignments"
echo "  join-submesh      open a specific agent's terminal"
echo "  stop-submesh      stop one agent or the whole session"
echo "  mesh-whisper      inject a note into a running agent's context"
echo "  submesh-help      full command reference"
echo ""
echo "Hooks registered in every agent workspace:"
echo "  render-guard.py   PreToolUse, BLOCKS video renders (set RENDER_GUARD_HANDOFF_URI)"
echo "  desk-prefix.sh    sourced by every tool — set SUBMESH_DESK_PREFIX per desktop"
echo ""
echo "To refresh the KDE desktop icon in a running container:"
echo "  docker exec -u abc <container-name> bash -c \\"
echo "    'DISPLAY=:1 qdbus6 org.kde.plasmashell /PlasmaShell refreshCurrentShell 2>/dev/null; true'"
