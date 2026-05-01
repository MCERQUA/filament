#!/bin/bash
# submesh/install.sh — installs the Filament sub-mesh agent system
# onto any ubuntu-os desktop container (KDE Plasma + Claude Code).
# Idempotent — safe to re-run to update commands, templates, or the icon.
#
# Usage:
#   bash submesh/install.sh <config-dir>
#
# Examples:
#   bash submesh/install.sh /mnt/clients/ubuntu-os/config
#   bash submesh/install.sh /mnt/clients/ubuntu-os-josh/config
#
# What it installs:
#   - All submesh commands + hook scripts → <config-dir>/mesh-tools/bin/
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
    echo "  e.g. $0 /mnt/clients/ubuntu-os/config"
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

echo "Installing Filament sub-mesh to: $CONFIG_DIR"

# ── Directories ────────────────────────────────────────────────────────────────
mkdir -p "$BIN_DIR" "$TEMPLATE_DIR" "$ICON_DIR" "$APP_DIR" "$DESKTOP_DIR"
mkdir -p "$SUBMESH_DIR/agents/manager/workspace"
mkdir -p "$SUBMESH_DIR/agents/manager/memory"

# ── Commands + hooks ───────────────────────────────────────────────────────────
echo "  → Installing commands..."
cp "$SCRIPT_DIR/bin/"* "$BIN_DIR/"
chmod +x "$BIN_DIR/"*

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
Exec=/config/mesh-tools/bin/submesh-launch
Icon=/config/.local/share/icons/submesh.svg
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
    echo 'case ":$PATH:" in *":/config/mesh-tools/bin:"*) ;; *) export PATH="/config/mesh-tools/bin:$PATH" ;; esac' >> "$BASHRC"
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
echo "To refresh the KDE desktop icon in a running container:"
echo "  docker exec -u abc <container-name> bash -c \\"
echo "    'DISPLAY=:1 qdbus6 org.kde.plasmashell /PlasmaShell refreshCurrentShell 2>/dev/null; true'"
