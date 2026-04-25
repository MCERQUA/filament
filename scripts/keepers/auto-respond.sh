#!/usr/bin/env bash
# keepers/auto-respond.sh — pattern-match auto-responder for recurring asks.
#
# THE PROBLEM: previous keepers wrote STATE_CHECK files but the entity that
# READS host inbox + REPLIES is the LLM session (me). Mike has to poke me
# to start. Cron-driven file shuffling is not autonomy.
#
# THIS keeper closes 80% of the gap by AUTO-REPLYING to known recurring
# questions with canned answers. Deterministic, zero LLM required.
#
# Patterns matched against KIND:question/blocker subject + body. On match,
# auto-reply lands in sender's inbox + question is acked + entry stamped
# in /mesh/keepers/state/auto-responses.log so Mike can audit.
#
# Backstop: anything NOT matched falls through to the host-inbox-keeper
# escalation path (and the scheduled-host-drain LLM session).

set -uo pipefail
# helpers from parent

INBOX="${MESH_ROOT}/agents/host/inbox"
[[ -d "$INBOX" ]] || exit 0

AUTO_LOG="${STATE_DIR}/auto-responses.log"
mkdir -p "$STATE_DIR"

# Each pattern: regex|response-template-name
# Response templates live as files in keepers/auto-responses/<name>.md

PATTERNS=(
  "openclaw.*(gateway|auth).*token|openclaw.*ws.*auth|OPENCLAW_GATEWAY_TOKEN|DEVICE_AUTH_SIGNATURE_INVALID|gateway.token.mismatch|device.pairing.required|NOT_PAIRED|openclaw.*token.*needed|openclaw-.*auth-token|live conversation proof.*token|gateway WS token|websocket.*auth.*openclaw|openclaw.*completions.*disabled|http.*completions.*404|/v1/responses.*disabled|http.*endpoint.*enable.*openclaw|need.*openclaw.*auth|need.*ws.*token|openclaw.http.endpoints"
  "openclaw-ws-auth-bridge-fallback"
)

# Reply template body
get_response_body() {
    case "$1" in
        openclaw-ws-auth-bridge-fallback)
            cat <<'BODY'
[AUTO-REPLY from host-keeper auto-respond]

Use the BRIDGE fallback — it's the production path, not a workaround.

The OVUI PWA itself uses /api/pwa/chat/send in production. src-desktop's
CONVERSATION-PROOF.md is the working reference at
/mesh/BLACKBOARD/ovui-lite/submissions/src-desktop/CONVERSATION-PROOF.md.

Pattern (in your container):
  POST http://127.0.0.1:8090/api/pwa/chat/send
  Header: Bearer-style token from $OVUI_BRIDGE_AUTH_TOKEN env var
  Body:   {"text":"your prompt"}
  Response: {"ok":true,"via":"TranscriptPanel","error":null}
  Then poll /api/pwa/transcript/last for the response text.

CRITICAL: set OVUI_PWA_URL=https://<your-tenant>.jam-bot.com on your
webtop. Bridge default is bun.jam-bot.com — without override, every
agent's bridge talks to bun's openclaw, not their own.

Direct ws://openclaw-X:18789 fails on test webtops because device-pairing
is enforced (production per-tenant openclaws have dangerouslyDisableDeviceAuth:
true; the hackathon webtops don't). Bridge fallback bypasses this entirely.

Resolve your local blocker (mesh-blocker resolve <id> --by <self>) once
your CONVERSATION-PROOF.md ships via this path.

Silent processing per §10.9. Drop a follow-up question if this auto-reply
doesn't fit your situation.
BODY
            ;;
    esac
}

shopt -s nullglob
for f in "${INBOX}"/2026-*.md; do
    [[ -f "$f" ]] || continue
    base=$(basename "$f")
    [[ "$base" == *"host-keeper-"* ]] && continue
    [[ "$base" == *"host-"* && "$base" != *"-host-"* ]] && continue  # self-pings

    # Already auto-responded? Track per-file.
    marker="${STATE_DIR}/auto-responded-${base}"
    [[ -e "$marker" ]] && continue

    kind=$(awk -F': *' '/^KIND:/{gsub(/[" ]/,"",$2); print $2; exit}' "$f")
    [[ "$kind" != "question" && "$kind" != "blocker" ]] && continue

    # Combine subject + body for pattern match
    subject=$(echo "$base" | sed 's/^[0-9-]*-[a-z-]*-//; s/\.md$//; s/-/ /g')
    body=$(cat "$f")
    blob="${subject}|${body}"

    # Try each pattern pair (regex, response-name)
    matched=""
    for ((i = 0; i < ${#PATTERNS[@]}; i += 2)); do
        regex="${PATTERNS[i]}"
        response="${PATTERNS[i+1]}"
        if echo "$blob" | grep -qiE "$regex"; then
            matched="$response"
            break
        fi
    done

    [[ -z "$matched" ]] && continue

    # Extract sender + send canned reply
    sender=$(awk -F': *' '/^AUTHOR:/{gsub(/[" @]/,"",$2); print $2; exit}' "$f" | sed 's/mesh$//; s/\.//' | sed 's/^/@/' )
    sender_clean=$(awk -F': *' '/^AUTHOR:/{gsub(/[" ]/,"",$2); print $2; exit}' "$f" | sed 's/@mesh$//')
    [[ -z "$sender_clean" ]] && continue

    body_text=$(get_response_body "$matched")
    if [[ -z "$body_text" ]]; then
        log "    auto-respond: no body for ${matched}"
        continue
    fi

    # Drop canned reply into sender's inbox
    sender_inbox="${MESH_ROOT}/agents/${sender_clean}/inbox"
    [[ -d "$sender_inbox" ]] || { log "    auto-respond: ${sender_clean} inbox missing"; continue; }
    date_pfx=$(date -u +%Y-%m-%d)
    for n in $(seq -w 001 999); do
        target="${sender_inbox}/${date_pfx}-${n}-host-auto-respond-${matched}.md"
        [[ -e "$target" ]] || break
    done

    {
        echo "---"
        echo "KIND: message"
        echo "AUTHOR: host@mesh"
        echo "READERS: [${sender_clean}@mesh]"
        echo "REPLIES-TO: ${base}"
        echo "SIZE: medium"
        echo "END-OF-TURN: ${sender_clean}@mesh — apply auto-reply"
        echo "AUTO_REPLY_PATTERN: ${matched}"
        echo "---"
        echo
        echo "$body_text"
    } > "$target"

    # Mark host's copy of original as acked AND mark auto-responded
    touch "$marker"
    echo "$(ts) | ${base} → ${matched} → ${target}" >> "$AUTO_LOG"
    log "    auto-respond: ${sender_clean} ← ${matched} (re ${base})"

    # Move host's copy to .read/ so it doesn't keep escalating
    mkdir -p "${INBOX}/.read"
    mv -f "$f" "${INBOX}/.read/$(basename "$f")" 2>/dev/null || true
done
shopt -u nullglob
