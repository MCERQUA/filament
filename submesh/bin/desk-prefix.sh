#!/usr/bin/env bash
# desk-prefix.sh — THE single source of truth for a desk's submesh identity prefix.
#
# A submesh on a desktop node mints its workers as <PREFIX>-<slot>@mesh
# (slot 1 = manager, 2..4 = workers). Every desktop that runs a submesh MUST resolve
# a DIFFERENT prefix, or two desktops' workers claim the same mesh identities.
#
# ── WHY THIS FILE EXISTS ──────────────────────────────────────────────────────
# The prefix chain used to be duplicated verbatim in FOUR executables — new-agent,
# submesh-launch, stop-submesh, submesh-agents. A fix landed in one copy and the other
# three stayed stale; it was caught within the hour ("two files, not one" — it was
# four). Fixing one copy of duplicated logic and declaring the bug closed is the same
# defect the fix was for, one level up. All tools now source this one file.
#
# THE ORIGINAL BUG: the chain matched hostname SUBSTRINGS with the generic case last.
# When every desktop container's hostname shares a common base (e.g. every webtop is
# "webtop-ubuntu-os-<something>"), a generic `*ubuntu*` test matches ALL of them:
#     webtop-ubuntu-os          -> ubuntu-desk   correct — the original desktop
#     webtop-ubuntu-os-carol    -> ubuntu-desk   WRONG, the original desktop's namespace
#     webtop-ubuntu-os-dave     -> ubuntu-desk   WRONG, the original desktop's namespace
#     webtop-ubuntu-os-bob      -> bob-desk      correct ONLY because bob was tested first
# so two desktops minted workers into ANOTHER desktop's slot namespace while writing into
# their own mounts. Measured before the fix: two desks both held `2:worker-1 3:worker-2
# 4:worker-3`, i.e. both claimed the same <prefix>-2/3/4@mesh. submesh-launch is worse
# than new-agent here — it sets MANAGER_URI="${PREFIX}-1@mesh", so the MANAGER collides too.
#
# RESOLUTION ORDER (first hit wins):
#   1. SUBMESH_DESK_PREFIX            explicit override — set this and nothing else runs
#   2. AGENT_URI=<name>-desktop@mesh  -> <name>-desk   (AGENT_URI is the authoritative
#                                      per-desk identity, so prefer it)
#   3. SUBMESH_HOST_PREFIX_MAP        hostname fallback, "glob=prefix;glob=prefix;..."
#                                      evaluated IN THE ORDER GIVEN. List MOST-SPECIFIC
#                                      FIRST: a substring chain orders by accident, and
#                                      "bob beat ubuntu only because of line order" is
#                                      luck, not design.
#                                      e.g. SUBMESH_HOST_PREFIX_MAP='*-bob=bob-desk;*-carol=carol-desk;*ubuntu*=alice-desk'
#   4. "desk"                         generic default (single-desktop installs)
#
# Usage:  . "$(dirname "$0")/desk-prefix.sh"   ->  sets $PREFIX
# Callers MUST keep working if this file is absent (older deployments), so each one
# guards the source and falls back to a minimal inline copy (override + AGENT_URI + "desk").

desk_prefix() {
    local hn uri map pair glob pfx
    if [ -n "${SUBMESH_DESK_PREFIX:-}" ]; then
        echo "$SUBMESH_DESK_PREFIX"; return
    fi
    uri="${AGENT_URI:-}"
    case "$uri" in
        *-desktop@*)    echo "${uri%%-desktop@*}-desk"; return ;;
    esac
    hn="$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null)"
    map="${SUBMESH_HOST_PREFIX_MAP:-}"
    if [ -n "$map" ] && [ -n "$hn" ]; then
        local IFS=';'
        for pair in $map; do
            glob="${pair%%=*}"; pfx="${pair#*=}"
            [ -n "$glob" ] && [ -n "$pfx" ] && [ "$glob" != "$pair" ] || continue
            # shellcheck disable=SC2254  # the glob IS the pattern
            case "$hn" in $glob) echo "$pfx"; return ;; esac
        done
    fi
    echo "desk"
}

PREFIX="$(desk_prefix)"
