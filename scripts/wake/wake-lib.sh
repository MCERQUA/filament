# shellcheck shell=bash
# wake-lib.sh — shared helpers for dropping prompts into live agent sessions.
#
# Source it; do not execute it. Every tool in scripts/wake/ uses these helpers so the
# tag format, the ledger shape and the tmux transport are defined exactly once.
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────────────
# `tmux send-keys` into an agent's pane is indistinguishable from the operator typing.
# It leaves no mesh trail and bypasses every check the mesh has, because the text never
# becomes a mesh message. An actor that can type into a pane never needs to forge a
# message at all. So every machine-typed line carries an ORIGIN TAG plus a NONCE, and
# the nonce is written to an append-only LEDGER *before* the keys are sent:
#
#     [wake:<producer>#<nonce>]
#
# A tag can be typed by anyone. A tag whose nonce has no ledger record — or whose ledger
# record names a different producer — was not sent through these tools, and the
# receiving agent can check (scripts/wake/wake-verify). Ledger-first also means a wake
# that never arrives is still evidenced.
#
# LIMIT, stated plainly: anything running as the same uid can write the ledger too.
# Tagging raises the cost of an unattributed instruction and makes a forgery DETECTABLE
# rather than invisible; it does not make one impossible.
#
# ── CONFIG (env) ──────────────────────────────────────────────────────────────────
#   MESH_ROOT          mesh root (host layout: $MESH_ROOT/mesh, $MESH_ROOT/agents)
#   MESH_DIR           explicit shared mesh dir (overrides MESH_ROOT; e.g. /mesh in a container)
#   WAKE_LEDGER_DIR    ledger dir; default <mesh dir>/LEDGER/wakes  (one JSONL per UTC day)
#   AGENT_URI          who is sending (recorded in the ledger)
#   WAKE_TMUX          tmux command prefix, word-split. Default "tmux". Examples:
#                        "tmux -L mysocket"                 private tmux socket
#                        "docker exec -u app mycontainer tmux"  pane inside a container
#                      (ssh is NOT supported as a prefix: ssh re-joins argv into a remote
#                       shell string and the literal text would be re-parsed. Run the wake
#                       tool on the remote side instead.)

# Resolve the shared mesh dir: explicit > MESH_ROOT > container (/mesh) > host default.
wake_mesh_dir() {
    if [ -n "${MESH_DIR:-}" ]; then printf '%s\n' "$MESH_DIR"; return; fi
    if [ -n "${MESH_ROOT:-}" ]; then printf '%s\n' "$MESH_ROOT/mesh"; return; fi
    if [ -d /mesh ] && [ -d /agent-desk ]; then printf '/mesh\n'; return; fi
    printf '/mnt/agent-mesh/mesh\n'
}

wake_ledger_dir() { printf '%s\n' "${WAKE_LEDGER_DIR:-$(wake_mesh_dir)/LEDGER/wakes}"; }
wake_ledger_file() { printf '%s/%s.jsonl\n' "$(wake_ledger_dir)" "$(date -u +%F)"; }

# 4 random bytes as lowercase hex. The verifier rejects any nonce that is not 6-16 hex
# chars, so a hand-typed "#fix" or "#test" tag is flagged MALFORMED on sight.
wake_nonce() { head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

wake_valid_nonce() { [[ "$1" =~ ^[0-9a-f]{6,16}$ ]]; }
wake_valid_origin() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; }

# Minimal JSON string escaping (backslash, quote, control chars -> space).
wake_json_str() {
    local s="$1"
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    printf '%s' "$s" | tr '\000-\037' ' '
}

# wake_ledger_append <event> <origin> <nonce> <target> <text> [verdict]
# Append-only. Failure to write is reported (return 1) so callers can refuse to send:
# an unledgered wake is exactly the thing the verifier is built to flag.
wake_ledger_append() {
    local ev="$1" origin="$2" nonce="$3" target="$4" text="$5" verdict="${6:-}"
    local f; f="$(wake_ledger_file)"
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
    printf '{"ts":"%s","event":"%s","agent":"%s","origin":"%s","nonce":"%s","target":"%s","text":"%s"%s}\n' \
        "$(date -u +%FT%TZ)" "$ev" "$(wake_json_str "${AGENT_URI:-unknown}")" \
        "$(wake_json_str "$origin")" "$nonce" "$(wake_json_str "$target")" \
        "$(wake_json_str "${text:0:300}")" \
        "${verdict:+,\"verdict\":\"$(wake_json_str "$verdict")\"}" >> "$f" 2>/dev/null
}

# Tag placement: a slash command must stay first on the line or the CLI will not parse it
# as a command, so the tag is APPENDED to "/cmd ..." and PREFIXED to anything else.
wake_tagged_line() {  # <origin> <nonce> <text>
    case "$3" in
        /*) printf '%s [wake:%s#%s]' "$3" "$1" "$2" ;;
        *)  printf '[wake:%s#%s] %s' "$1" "$2" "$3" ;;
    esac
}

# tmux transport ----------------------------------------------------------------
_wake_tmux_init() {
    # shellcheck disable=SC2206
    [ -n "${_WT_INIT:-}" ] || { read -r -a _WT <<< "${WAKE_TMUX:-tmux}"; _WT_INIT=1; }
}
wt() { _wake_tmux_init; "${_WT[@]}" "$@"; }
wake_tmux_is_local() { _wake_tmux_init; [ "${_WT[0]}" = "tmux" ]; }

wake_capture()      { wt capture-pane -p -t "$1" 2>/dev/null; }
wake_capture_hist() { wt capture-pane -p -S "-${2:-200}" -t "$1" 2>/dev/null; }
wake_pane_cmd()     { wt display-message -p -t "$1" '#{pane_current_command}' 2>/dev/null | tr -d '\r\n '; }
wake_pane_in_mode() { wt display-message -p -t "$1" '#{pane_in_mode}' 2>/dev/null | tr -d '\r\n '; }
wake_frame_hash()   { wake_capture "$1" | md5sum | cut -c1-32; }

# AGENT_URI of the process running in the pane ("" if it cannot be read). Only possible
# when tmux is local, because it reads /proc. Used to refuse a wake aimed at the wrong
# agent: a watcher list that named the wrong pane once turned every inbox nudge for one
# agent into a false work order for a different one.
wake_pane_identity() {
    wake_tmux_is_local || return 0
    local pid child
    pid=$(wt list-panes -t "$1" -F '#{pane_pid}' 2>/dev/null | head -1)
    [ -n "$pid" ] || return 0
    for child in "$pid" $(pgrep -P "$pid" 2>/dev/null); do
        tr '\0' '\n' < "/proc/$child/environ" 2>/dev/null | sed -n 's/^AGENT_URI=//p' | head -1 | grep . && return 0
    done
    return 0
}

# The prompt line: the last pane line carrying the prompt glyph, glyph and padding stripped.
# Claude Code pads its prompt with a NON-BREAKING SPACE (U+00A0), which [[:space:]] does not
# match — convert it first or an "empty" prompt reads as staged text forever.
wake_prompt_line() {  # <pane-text> <glyph>
    [ -n "$2" ] || return 0
    printf '%s\n' "$1" | grep -F -- "$2" | tail -1 \
        | sed "s/.*$2//" | sed 's/\xc2\xa0/ /g' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}
