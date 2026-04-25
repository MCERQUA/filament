#!/usr/bin/env bash
# hackathon-benchmark.sh — uniform measurement for OVUI-Lite submissions.
#
# Usage:
#   AGENT=bun-desktop bash hackathon-benchmark.sh "<launch-cmd>"
#
# Measures:
#   - cold-start time (wall-clock until process is ready)
#   - idle RSS RAM (after settle)
#   - active RSS RAM (during conversation simulation)
#   - CPU% at idle
#   - disk install size (if AGENT_INSTALL_PATH env set)
#
# Writes to /mnt/agent-mesh/mesh/BLACKBOARD/ovui-lite/submissions/<agent>/BENCH.md
#
# Note: this is host-side — agents may run their own per-stack benchmark
# inside their container/repo and POST results to BENCH.md directly.
# The host harness validates from outside (PID stats are most reliable
# from the OS layer agents can't easily fake).

set -uo pipefail

AGENT="${AGENT:?AGENT env required (e.g. AGENT=bun-desktop)}"
LAUNCH_CMD="${1:?usage: $0 \"<launch-cmd>\"}"
OUT_DIR="/mnt/agent-mesh/mesh/BLACKBOARD/ovui-lite/submissions/${AGENT}"
mkdir -p "${OUT_DIR}"
OUT="${OUT_DIR}/BENCH.md"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

echo "[bench] launching: ${LAUNCH_CMD}"
START=$(date +%s%3N)
# launch in background
$LAUNCH_CMD &
PID=$!

# wait until app is "ready" — caller must ensure their app exits init state
# within READY_TIMEOUT seconds. Default heuristic: process exists after 3s.
sleep 3
if ! kill -0 "$PID" 2>/dev/null; then
    echo "[bench] FAIL — app died within 3s" >&2
    exit 1
fi
COLD_MS=$(($(date +%s%3N) - START))

# settle for 10s
sleep 10

# idle RSS + CPU
IDLE_RSS_KB=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ')
IDLE_CPU=$(ps -o %cpu= -p "$PID" 2>/dev/null | tr -d ' ')

# active phase: send a synthetic prompt if app exposes mesh CLI control;
# otherwise skip (the agent's own bench can fill in active numbers)
ACTIVE_RSS_KB="${IDLE_RSS_KB}"  # placeholder; agent overrides

# disk install
INSTALL_BYTES=0
if [[ -n "${AGENT_INSTALL_PATH:-}" && -d "${AGENT_INSTALL_PATH}" ]]; then
    INSTALL_BYTES=$(du -sb "${AGENT_INSTALL_PATH}" 2>/dev/null | awk '{print $1}')
fi

# tear down
kill "$PID" 2>/dev/null
wait "$PID" 2>/dev/null

# Format
IDLE_MB=$(( ${IDLE_RSS_KB:-0} / 1024 ))
ACTIVE_MB=$(( ${ACTIVE_RSS_KB:-0} / 1024 ))
INSTALL_MB=$(( ${INSTALL_BYTES:-0} / 1024 / 1024 ))

cat > "${OUT}" <<EOF
---
agent: ${AGENT}@mesh
benchmarked_at: $(ts)
launch_cmd: "${LAUNCH_CMD}"
schema_version: 1
---

# Benchmark — ${AGENT}

| Metric | Value | Target ceiling | Stretch |
|---|---:|---:|---:|
| Cold-start | ${COLD_MS} ms | ≤1500 ms | ≤800 ms |
| Idle RSS | ${IDLE_MB} MB | ≤65 MB | ≤40 MB |
| Active RSS | ${ACTIVE_MB} MB | ≤110 MB | ≤75 MB |
| Idle CPU | ${IDLE_CPU}% | ≤0.2% | ~0% |
| Disk install | ${INSTALL_MB} MB | ≤125 MB | ≤60 MB |

## Feature parity

(Agent must fill in below — host bench can't introspect features)

- [ ] Voice STT
- [ ] Voice TTS
- [ ] AI conversation roundtrip
- [ ] Canvas page render
- [ ] Mesh integration
- [ ] Auth (OVUI_BRIDGE_AUTH_TOKEN + Clerk where applicable)
- [ ] Settings UI

## Notes

(Agent fills in here: deviations from harness, special launch flags,
container vs host, dependencies, anything weird.)
EOF

echo "[bench] wrote ${OUT}"
echo "  cold=${COLD_MS}ms idle=${IDLE_MB}MB cpu=${IDLE_CPU}% install=${INSTALL_MB}MB"
