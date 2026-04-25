#!/usr/bin/env bash
# demo.sh -- send a ping from agent-a to agent-b, watch agent-b reply.
#
# Run after `docker compose up -d`. No sudo needed.

set -euo pipefail

A=filament-agent-a
B=filament-agent-b

ensure_running() {
    if ! docker inspect "$1" >/dev/null 2>&1; then
        echo "Container $1 not found. Run: docker compose up -d" >&2
        exit 1
    fi
}

ensure_running "$A"
ensure_running "$B"

echo "> agent-a sends ping to agent-b"
docker exec "$A" bash -c '
    AGENT_URI=agent-a@mesh MESH_ROOT=/mesh mesh-send \
        --to agent-b@mesh \
        --kind ping \
        --subject "hello from agent-a" \
        <<< "ping body $(date -uIs)"
'

echo
echo "> agent-b inbox:"
docker exec "$B" bash -c '
    AGENT_URI=agent-b@mesh MESH_ROOT=/mesh ls /mesh/agents/agent-b/inbox/ | grep -v "^.read$"
'

echo
echo "> agent-b reads + acks one message"
docker exec "$B" bash -c '
    AGENT_URI=agent-b@mesh MESH_ROOT=/mesh mesh-recv | head -30
    # ack the most recent inbox file
    last=$(ls -t /mesh/agents/agent-b/inbox/*.md 2>/dev/null | head -1)
    if [[ -n "$last" ]]; then
        AGENT_URI=agent-b@mesh MESH_ROOT=/mesh mesh-ack "$(basename "$last")"
    fi
'

echo
echo "> agent-b replies"
docker exec "$B" bash -c '
    AGENT_URI=agent-b@mesh MESH_ROOT=/mesh mesh-send \
        --to agent-a@mesh \
        --kind reply \
        --subject "pong from agent-b" \
        <<< "pong body $(date -uIs)"
'

echo
echo "> agent-a inbox after reply:"
docker exec "$A" bash -c '
    AGENT_URI=agent-a@mesh MESH_ROOT=/mesh mesh-recv | head -20
'

echo
echo "+ round-trip complete."
echo "  agent-a sent/:"
docker exec "$A" ls /mesh/agents/agent-a/sent/ | sed "s/^/    /"
echo "  agent-b sent/:"
docker exec "$B" ls /mesh/agents/agent-b/sent/ | sed "s/^/    /"
