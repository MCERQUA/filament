#!/usr/bin/env bash
# keepers/hackathon.sh — active oversight for OVUI-Lite hackathon.
#
# Policy:
#   For each agent in the hackathon roster:
#     A. If they have NOT claimed (no ANGLE.md):
#        - Re-drop the angle-claim task every 30 min (until phase 1 deadline)
#     B. If they HAVE claimed AND repo has no commit in last 30 min:
#        - Re-drop a "keep building" task tailored to the next missing
#          floor feature (estimated from current STATUS.md / repo files)
#     C. If 4+ consecutive re-drops produced no commit:
#        - Escalate to host inbox (suggests genuine block, not idle agent)

set -uo pipefail

# Helpers come from parent mesh-keeper.sh — they're exported

REDROP_QUIET_SEC=$((30 * 60))      # 30 min of repo silence ⇒ redrop
REDROP_INTERVAL_SEC=$((30 * 60))   # don't re-drop more often than this
ESCALATE_AFTER_REDROPS=4

declare -A REPO=(
  [bun-desktop]=ovui-lite-bun-desktop
  [josh-desktop]=ovui-lite-josh-desktop
  [danielle-desktop]=ovui-lite-danielle-desktop
  [src-desktop]=ovui-lite-src-desktop
  [residential-laptop]=ovui-lite-residential-laptop
)

HACK_DIR="${MESH_ROOT}/mesh/BLACKBOARD/ovui-lite"

# Phase clock (only used to skip Phase 6+)
P5_END=$(date -u -d '2026-04-28T16:00:00Z' +%s)
if (( NOW > P5_END )); then
    log "    hackathon past Phase 5 — keeper exiting"
    exit 0
fi

for agent in "${!REPO[@]}"; do
    repo="${REPO[$agent]}"
    angle_file="${HACK_DIR}/submissions/${agent}/ANGLE.md"

    # ---- Branch A: no claim yet ----
    if [[ ! -r "$angle_file" ]]; then
        subject="hackathon-claim-nudge"
        last=$(last_redrop "$agent" "$subject")
        if (( NOW - last < REDROP_INTERVAL_SEC )); then
            continue
        fi
        body=$(mktemp)
        cat > "$body" <<EOF
DEADLINE: 2026-04-25T18:00:00Z
PRIORITY: 1
QUEUE: ovui-lite-hackathon

KEEPER NUDGE — you have NOT claimed an angle yet for the OVUI-Lite hackathon. Read /mesh/BLACKBOARD/ovui-lite/BRIEF.md and pick from open angles.

Open right now (refreshed each keeper run):
$(for a_id in A B E G H X; do
    if ! grep -q "^angle_id: ${a_id}$" "${HACK_DIR}/submissions"/*/ANGLE.md 2>/dev/null; then
        echo "- ${a_id}"
    fi
done)

Action:
1. mkdir-claim /mesh/BLACKBOARD/ovui-lite/submissions/${agent}/ANGLE.md.claim
2. Write ANGLE.md (schema in BRIEF §Phase 1)
3. Begin Phase 2 build IMMEDIATELY after claim — don't wait for the global deadline
4. cd ~/Projects/${repo} ; git pull ; build ; commit ; push

Repo + SSH key already provisioned: see BRIEF "Repos (PRE-PROVISIONED)" section.

Silent processing per §10.9.
EOF
        redrop_task "$agent" "$subject" "$body"
        rm -f "$body"
        continue
    fi

    # ---- Branch B: claimed, check repo activity ----
    last_iso=$(gh api "repos/MCERQUA/${repo}/commits?per_page=1" 2>/dev/null \
        | python3 -c "import json,sys; c=json.load(sys.stdin); print(c[0]['commit']['author']['date'] if c else '')" 2>/dev/null)
    if [[ -z "$last_iso" ]]; then
        log "    ${agent}: no commits readable (api?) — skipping"
        continue
    fi
    last_epoch=$(date -u -d "${last_iso}" +%s 2>/dev/null)
    [[ -z "$last_epoch" ]] && continue
    quiet=$((NOW - last_epoch))

    # If commit is fresh, reset redrop counter
    if (( quiet < REDROP_QUIET_SEC )); then
        reset_redrop "$agent" "hackathon-build-nudge"
        log "    ${agent}: active (${quiet}s since last commit)"
        continue
    fi

    subject="hackathon-build-nudge"
    last_redrop_epoch=$(last_redrop "$agent" "$subject")
    if (( NOW - last_redrop_epoch < REDROP_INTERVAL_SEC )); then
        continue
    fi

    # Estimate next missing feature by scanning repo for keywords
    next_feature="(read STATUS.md to remember where you stopped)"
    repo_listing=$(gh api "repos/MCERQUA/${repo}/git/trees/main?recursive=1" 2>/dev/null \
        | python3 -c "import json,sys; t=json.load(sys.stdin); print('\n'.join(x['path'] for x in t.get('tree',[]) if x.get('type')=='blob'))" 2>/dev/null)
    if [[ -n "$repo_listing" ]]; then
        if ! echo "$repo_listing" | grep -qiE 'stt|whisper|speech.recognition|asr'; then
            next_feature="Voice STT — no STT-related file found in repo. Implement next."
        elif ! echo "$repo_listing" | grep -qiE 'tts|text.to.speech|synth'; then
            next_feature="Voice TTS — no TTS-related file found. Implement next."
        elif ! echo "$repo_listing" | grep -qiE 'openclaw|gateway|conversation|chat'; then
            next_feature="AI conversation — wire up openclaw gateway (ws://openclaw:18789 or http) and stream a response."
        elif ! echo "$repo_listing" | grep -qiE 'canvas|page'; then
            next_feature="Canvas page render — open arbitrary HTML page from /pages/<id>.html in a frame/window."
        elif ! echo "$repo_listing" | grep -qiE 'mesh.send|mesh.recv|mesh.client'; then
            next_feature="Mesh integration — call mesh-send/mesh-recv from the app or proxy via /config/.local/bin/."
        elif ! echo "$repo_listing" | grep -qiE 'auth|bearer|token|clerk'; then
            next_feature="Auth — OVUI_BRIDGE_AUTH_TOKEN env var + Clerk session for browser variant."
        elif ! echo "$repo_listing" | grep -qiE 'settings|config'; then
            next_feature="Settings UI — view/edit voice provider, model, mesh agent URI."
        else
            next_feature="All floor features named in repo — verify each ACTUALLY works end-to-end. Then run the benchmark and start hitting stretch targets."
        fi
    fi

    body=$(mktemp)
    cat > "$body" <<EOF
DEADLINE: 2026-04-27T18:00:00Z
PRIORITY: 1
QUEUE: ovui-lite-hackathon

KEEPER ACTIVE-PROMPT — your repo (https://github.com/MCERQUA/${repo}) has had NO commits in $((quiet / 60)) minutes. We are in Phase 2 build for you (per-agent, ignoring global phase clock).

Re-drop count for this workstream: $(redrop_count "$agent" "$subject"). After ${ESCALATE_AFTER_REDROPS}, host will escalate.

NEXT TASK FOR YOU (estimated from repo contents):
${next_feature}

Procedure:
1. cd ~/Projects/${repo}
2. git pull
3. Read STATUS.md
4. Implement the next missing floor feature (above)
5. Commit + push
6. Update STATUS.md with % done + next step + commit SHA
7. Repeat — keep building until all 7 floor features are in place AND verified working

Resource ceiling: idle RSS ≤65 MB, active ≤110 MB, cold ≤1.5s, install ≤125 MB.

If genuinely stuck: KIND: blocker to host with SLA_MINUTES.

Silent processing per §10.9. Do NOT just ack and stop. Build.
EOF
    redrop_task "$agent" "$subject" "$body"
    rm -f "$body"

    # Escalate if too many re-drops
    rc=$(redrop_count "$agent" "$subject")
    if (( rc >= ESCALATE_AFTER_REDROPS )); then
        escalate "$agent" "hackathon: ${rc} consecutive re-drops, no commit in $((quiet / 60))m"
    fi
done
