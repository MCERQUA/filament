#!/usr/bin/env bash
# agent-session.sh — persistent agent session: ONE shared tmux session, a respawn loop
# around the agent CLI, and an idempotent boot prompt (default /mesh-start).
#
# Use it as the login shell of a web terminal (ttyd, wetty), a desktop launcher, or a
# service's ExecStart. Every opener attaches to the same session; the first one creates
# it. Closing the terminal does NOT kill the agent — the conversation stays alive.
#
# USAGE
#   agent-session.sh                 attach (creating the session if needed)
#   agent-session.sh --detached      create if needed, fire the boot prompt, do not attach
#   agent-session.sh --respawn-loop  (internal) the pane command that runs the CLI forever
#   agent-session.sh -h | --help
#
# ENV
#   AGENT_SESSION        tmux session name (default: agent-mesh)
#   AGENT_TMUX_SOCKET    private tmux socket name (tmux -L); default: the user's server
#   AGENT_WORKDIR        cwd for the CLI (default: $PWD)
#   AGENT_CLI            agent executable (default: claude)
#   AGENT_CLI_ARGS       extra args, word-split (default: none; e.g. a permissions flag)
#   AGENT_CONTINUE_FLAG  flag that resumes the last conversation (default: --continue;
#                        empty = never resume, always start fresh)
#   AGENT_TRANSCRIPT_DIR where the CLI keeps this cwd's transcripts (*.jsonl). Default:
#                        <cli-home>/.claude/projects/<cwd with / -> ->, where <cli-home>
#                        is read from an `export HOME="..."` line in AGENT_CLI if it is a
#                        wrapper script, else $HOME.
#   BOOT_PROMPT          typed once the CLI shows its prompt (default: /mesh-start;
#                        empty disables). Tagged [wake:session-boot#<nonce>] + ledgered.
#   BOOT_DEADLINE        seconds to wait for the prompt before giving up (default 180)
#   BOOT_FORCE_AT_DEADLINE  1 = type the boot prompt anyway at the deadline (default 1)
#   SESSION_ENV_PASSTHROUGH  space-separated env var NAMES copied into the pane with
#                        `tmux new-session -e` (default: "PATH AGENT_URI MESH_ROOT MESH_DIR
#                        WAKE_LEDGER_DIR"). Add credential names deliberately: -e puts the
#                        value on a short-lived tmux client argv.
#   RESUME_PROMPT        text passed with the continue flag (default: the inert
#                        assessment prompt below)
set +e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=wake-lib.sh
. "$HERE/wake-lib.sh"

SESSION="${AGENT_SESSION:-agent-mesh}"
# All tmux calls go through wt (wake-lib) so a private socket applies everywhere.
export WAKE_TMUX="tmux${AGENT_TMUX_SOCKET:+ -L $AGENT_TMUX_SOCKET}"
WORKDIR="${AGENT_WORKDIR:-$PWD}"
CLI="${AGENT_CLI:-claude}"
command -v "$CLI" >/dev/null 2>&1 && CLI="$(command -v "$CLI")"
CONT_FLAG="${AGENT_CONTINUE_FLAG---continue}"
BOOT_PROMPT="${BOOT_PROMPT-/mesh-start}"

# ── transcript dir: ask the home the RESOLVED binary reads ─────────────────────────
# The respawn guard asks "is there a transcript to continue?" — a question about the
# EXECUTABLE, and a wrapper binary may override HOME (an alternate-provider wrapper of the
# same CLI typically does). A guard that hardcodes one home while the executor reads
# another says "continue", the CLI says "No conversation found to continue", exits in <1s,
# and the loop respawns it every 3s. Measured on one desk: 16,659 respawns in 17h, a
# single failure string, nothing alarmed, and a missed nightly reflection. Resolve the
# home from the binary's own declaration; never restate the constant.
if [ -z "${AGENT_TRANSCRIPT_DIR:-}" ]; then
    _home="$(sed -n 's/^export HOME="\([^"]*\)".*/\1/p' "$CLI" 2>/dev/null | head -1)"
    [ -n "$_home" ] && [ -d "$_home" ] || _home="$HOME"
    # The slug is cwd-derived by the CLI, so derive it from WORKDIR rather than typing it.
    AGENT_TRANSCRIPT_DIR="$_home/.claude/projects/$(printf '%s' "$WORKDIR" | tr '/' '-')"
fi
export AGENT_TRANSCRIPT_DIR

# A crash is when the lane's state is LEAST understood; a bare "continue" is the one
# instruction that presumes it IS understood. So the resume carries an INERT assessment
# prompt: it satisfies the resume path (no error, no menu) and is not a work order. In
# practice the resumed lane reported what was in flight and STOPPED without re-running an
# interrupted send.
DEFAULT_RESUME='SESSION RESTARTED BY THE RESPAWN LOOP after the previous one ended unexpectedly. You are NOT continuing it. Before any action: (1) state what the transcript shows was in flight; (2) check whether it actually completed - do not assume either way; (3) check whether another lane picked it up while you were down: run mesh-claim show <key> IF it is available, and treat a FATAL or unreachable result as CANNOT-TELL, never as free; if the tool is unavailable, look for recent peer messages about the same work instead. Do NOT re-run, resume or finish the interrupted action until those three are done. If its last action was destructive, or its outcome is unclear, or you could not determine whether another lane holds it, report and STOP.'
RESUME_PROMPT="${RESUME_PROMPT:-$DEFAULT_RESUME}"

case "${1:-}" in
    -h|--help) sed -n '2,/^set +e/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# ── the pane command ────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--respawn-loop" ]; then
    # shellcheck disable=SC2206
    ARGS=(${AGENT_CLI_ARGS:-})
    # GUARDED continue. A bare continue with no transcript for this cwd exits non-zero
    # instantly ("Provide a prompt to continue the conversation"), so an unconditional
    # continue turns `while true` into a permanently dark lane — and that fires on exactly
    # the empty-project-dir state a container recreate produces. A BARE respawn, on the
    # other hand, brings the lane back looking healthy with none of its context. So the
    # flag is chosen per iteration from whether a transcript actually exists right now.
    #
    # ⚠️ The guard stops the SPIN but does not make the continue branch fully safe: some
    # CLI versions come up on a blocking "Resume from summary / Resume full session" menu
    # for a LARGE transcript and sit there forever — alive, supervised, consuming nothing.
    # Passing a prompt with the flag has avoided it in practice; anything automating a
    # resume must verify on the ARTIFACT (a new assistant entry in the .jsonl), never on
    # the pid.
    #
    # SPIN BRAKE: two consecutive sub-10s exits means the continue branch cannot succeed
    # whatever the guard believes, so fall through to a fresh session for good. A wrong
    # guard then costs one fresh session, not a silent forever-loop.
    fails=0
    while true; do
        t0=$(date +%s)
        if [ -n "$CONT_FLAG" ] && [ "$fails" -lt 2 ] \
           && [ -n "$(ls -1t "$AGENT_TRANSCRIPT_DIR"/*.jsonl 2>/dev/null | head -1)" ]; then
            "$CLI" "${ARGS[@]}" "$CONT_FLAG" "$RESUME_PROMPT"
        else
            "$CLI" "${ARGS[@]}"
        fi
        if [ $(( $(date +%s) - t0 )) -lt 10 ]; then fails=$((fails+1)); else fails=0; fi
        echo; echo "[agent exited $(date -Iseconds), respawning in 3s — Ctrl-C to abort]"
        sleep 3
    done
fi

cd "$WORKDIR" 2>/dev/null || cd "$HOME" || exit 1

# Server-level: never reap the server when the last client detaches. Set before any
# session is created so it applies to the first one.
wt set-option -g exit-empty off 2>/dev/null

# ── idempotent boot prompt ──────────────────────────────────────────────────────────
# Runs on BOTH the create and the attach path, so a session that came up without its
# boot prompt (crash before it fired, server restart) still gets one. It skips when the
# prompt already appears in scrollback — the boot prompt itself must also be idempotent,
# because a cleared or rolled-over scrollback will fire it again.
fire_boot_when_ready() {
    [ -n "$BOOT_PROMPT" ] || return 0
    export WAKE_EXPECT_CMD="${WAKE_EXPECT_CMD-$(basename "$CLI")|claude}"
    (
        deadline="${BOOT_DEADLINE:-180}"; elapsed=0
        while [ "$elapsed" -lt "$deadline" ]; do
            sleep 2; elapsed=$((elapsed + 2))
            if wake_capture_hist "$SESSION" 500 | grep -qF -- "$BOOT_PROMPT"; then exit 0; fi
            if wake_capture "$SESSION" | grep -qF -- "${WAKE_PROMPT_GLYPH-❯}"; then
                WAKE_TRANSCRIPT_DIR="$AGENT_TRANSCRIPT_DIR" \
                    "$HERE/mesh-wake" --target "$SESSION" --origin session-boot --text "$BOOT_PROMPT" >/dev/null 2>&1
                exit 0
            fi
        done
        if [ "${BOOT_FORCE_AT_DEADLINE:-1}" = 1 ]; then
            WAKE_TRANSCRIPT_DIR="$AGENT_TRANSCRIPT_DIR" \
                "$HERE/mesh-wake" --target "$SESSION" --origin session-boot --no-ready-gate \
                --text "$BOOT_PROMPT" >/dev/null 2>&1
        fi
    ) >/dev/null 2>&1 &
    disown $! 2>/dev/null
}

attach() { [ "${1:-}" = "--detached" ] && exit 0; _wake_tmux_init; exec "${_WT[@]}" attach-session -t "$SESSION"; }

# REATTACH PATH: the session exists -> join the running agent. This is what makes
# "close the window, reopen it, the conversation is still there" work.
if wt has-session -t "$SESSION" 2>/dev/null; then
    fire_boot_when_ready
    attach "${1:-}"
fi

# CREATE PATH.
if ! command -v "$CLI" >/dev/null 2>&1 && [ ! -x "$CLI" ]; then
    # Last resort: no agent binary, give a shell (-A so fallback shells reattach too).
    [ "${1:-}" = "--detached" ] && exit 1
    _wake_tmux_init; exec "${_WT[@]}" new-session -A -s "$SESSION" /bin/bash -il
fi

# The pane inherits the tmux SERVER's environment, captured when the server first
# started — not this script's. If something else started the server earlier (a keeper,
# another session), the pane comes up with whatever that process had: a stale PATH
# ("command not found"), or an expired credential while this shell holds the live one.
# Pass what the loop needs explicitly with -e. Never pass an EMPTY value: an empty -e
# entry would shadow whatever the server env would otherwise have supplied.
ENVS=()
for v in ${SESSION_ENV_PASSTHROUGH:-PATH AGENT_URI MESH_ROOT MESH_DIR WAKE_LEDGER_DIR} \
         AGENT_CLI_ARGS AGENT_TRANSCRIPT_DIR RESUME_PROMPT; do
    [ -n "${!v:-}" ] && ENVS+=(-e "$v=${!v}")
done
export AGENT_CLI="$CLI" AGENT_CONTINUE_FLAG="$CONT_FLAG" RESUME_PROMPT
ENVS+=(-e "AGENT_CLI=$CLI" -e "AGENT_CONTINUE_FLAG=$CONT_FLAG")

wt new-session -d -s "$SESSION" -c "$WORKDIR" "${ENVS[@]}" "$SELF" --respawn-loop
wt set-option -t "$SESSION" history-limit 50000 >/dev/null 2>&1
fire_boot_when_ready
attach "${1:-}"
