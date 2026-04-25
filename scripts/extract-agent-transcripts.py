#!/usr/bin/env python3
"""
extract-agent-transcripts.py

Pulls Claude Code session transcripts from every mesh agent's container
(or host or laptop) and extracts a daily structured summary into
/mnt/agent-mesh/agents/<agent>/transcripts/<DATE>-claude-code.md.

Closes the visibility gap that left mesh nightly reflections work-blind.

Schedule: 03:00 UTC daily, 15 min before mesh-nightly-kickoff (03:15).

Per-agent input paths:
  bun-desktop        : docker exec webtop-ubuntu-os         /config/.claude/projects/**/*.jsonl
  josh-desktop       : docker exec webtop-ubuntu-os-josh    /config/.claude/projects/**/*.jsonl
  danielle-desktop   : docker exec webtop-ubuntu-os-danielle /config/.claude/projects/**/*.jsonl
  src-desktop        : docker exec webtop-ubuntu-os-src     /config/.claude/projects/**/*.jsonl
  host               :                                       /home/mike/.claude/projects/**/*.jsonl
  residential-laptop : ssh residential-laptop                /root/.claude/projects/**/*.jsonl  (best-effort, may be offline)

Output schema (markdown w/ frontmatter):

  ---
  agent: <agent>@mesh
  date: YYYY-MM-DD
  generated: <iso-ts>
  source_jsonl_count: N
  ---
  # <agent> — Claude Code transcript summary YYYY-MM-DD
  ## Sessions (N)
  ## User asks (M)
  ## Tool usage
  ## Files edited
  ## Bash commands
  ## Errors / failures
  ## Sub-agent spawns

stdlib-only. Python 3.8+.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import datetime as _dt
from pathlib import Path
from collections import Counter, defaultdict

MESH_ROOT = Path(os.environ.get("MESH_ROOT", "/mnt/agent-mesh"))
LOG = Path("/home/mike/MIKE-AI/logs/extract-agent-transcripts.log")

# (agent, mode, target) — mode ∈ {docker, local, ssh}
AGENTS = [
    ("bun-desktop",        "docker", "webtop-ubuntu-os"),
    ("josh-desktop",       "docker", "webtop-ubuntu-os-josh"),
    ("danielle-desktop",   "docker", "webtop-ubuntu-os-danielle"),
    ("src-desktop",        "docker", "webtop-ubuntu-os-src"),
    ("host",               "local",  "/home/mike/.claude/projects"),
    ("residential-laptop", "ssh",    "residential-laptop"),
]

CC_PROJECTS_REL = ".claude/projects"
DOCKER_CC = "/config/.claude/projects"
LAPTOP_CC = "/root/.claude/projects"


def ts() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def log(msg: str) -> None:
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as f:
        f.write(f"[{ts()}] {msg}\n")


def run(cmd: list[str], timeout: int = 120) -> tuple[int, str, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "TIMEOUT"
    except Exception as e:
        return 1, "", str(e)


def list_jsonl_for_date(agent: str, mode: str, target: str, date_str: str) -> list[str]:
    """Return list of JSONL paths modified on date_str (UTC). Path semantics
    differ per mode: for docker/ssh paths are container/laptop-side; for
    local paths are host-side directly."""
    if mode == "local":
        root = Path(target)
        if not root.is_dir():
            return []
        out = []
        # match by modified-date in UTC
        start = _dt.datetime.fromisoformat(date_str).replace(tzinfo=_dt.timezone.utc)
        end = start + _dt.timedelta(days=1)
        for p in root.rglob("*.jsonl"):
            try:
                mt = _dt.datetime.fromtimestamp(p.stat().st_mtime, tz=_dt.timezone.utc)
                if start <= mt < end:
                    out.append(str(p))
            except OSError:
                pass
        return out
    elif mode == "docker":
        # find files modified on date_str
        rc, stdout, stderr = run([
            "docker", "exec", target, "bash", "-c",
            f"find {DOCKER_CC} -name '*.jsonl' -newermt '{date_str} 00:00:00' "
            f"! -newermt '{date_str} 23:59:59' 2>/dev/null"
        ], timeout=60)
        if rc != 0:
            return []
        return [l.strip() for l in stdout.splitlines() if l.strip()]
    elif mode == "ssh":
        # Best-effort — laptop may be offline. Short timeout.
        rc, stdout, stderr = run([
            "ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes",
            target, "bash", "-c",
            f"find {LAPTOP_CC} -name '*.jsonl' -newermt '{date_str} 00:00:00' "
            f"! -newermt '{date_str} 23:59:59' 2>/dev/null"
        ], timeout=15)
        if rc != 0:
            return []
        return [l.strip() for l in stdout.splitlines() if l.strip()]
    return []


def fetch_jsonl_content(mode: str, target: str, path: str) -> str:
    if mode == "local":
        try:
            return Path(path).read_text(errors="replace")
        except OSError:
            return ""
    elif mode == "docker":
        rc, stdout, _ = run(["docker", "exec", target, "cat", path], timeout=120)
        return stdout if rc == 0 else ""
    elif mode == "ssh":
        rc, stdout, _ = run([
            "ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes",
            target, "cat", path
        ], timeout=60)
        return stdout if rc == 0 else ""
    return ""


def parse_session(jsonl_text: str) -> dict:
    """Pull structured summary from a single session's JSONL stream."""
    summary = {
        "user_asks": [],            # list of (ts, text-first-200-chars)
        "tool_calls": Counter(),    # tool_name -> count
        "files_edited": set(),      # Edit/Write/NotebookEdit paths
        "files_read": set(),        # Read paths
        "bash_cmds": [],            # list of (ts, command-first-120-chars)
        "subagent_spawns": [],      # list of (ts, description-first-120-chars)
        "errors": [],               # list of (ts, brief)
        "session_ids": set(),
        "model": None,
        "cwd": None,
        "git_branch": None,
        "turn_count": 0,
    }
    for line in jsonl_text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        sid = obj.get("sessionId")
        if sid:
            summary["session_ids"].add(sid)
        if "cwd" in obj and not summary["cwd"]:
            summary["cwd"] = obj["cwd"]
        if "gitBranch" in obj and not summary["git_branch"]:
            summary["git_branch"] = obj["gitBranch"]

        otype = obj.get("type")
        # User turn (text from human / hook)
        if otype == "user":
            msg = obj.get("message", {})
            content = msg.get("content")
            text_chunks = []
            if isinstance(content, str):
                text_chunks.append(content)
            elif isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "text":
                        text_chunks.append(c.get("text", ""))
            text = " ".join(text_chunks).strip()
            # Filter out tool-result echoes (the harness puts those in user turns too)
            if text and not text.startswith("<system-reminder>") and len(text) > 20:
                t = obj.get("timestamp", "")
                summary["user_asks"].append((t, text[:200]))
                summary["turn_count"] += 1
        # Assistant turn — capture tool_use blocks
        elif otype == "assistant":
            msg = obj.get("message", {})
            if not summary["model"] and msg.get("model"):
                summary["model"] = msg["model"]
            for c in msg.get("content", []) or []:
                if isinstance(c, dict) and c.get("type") == "tool_use":
                    name = c.get("name", "")
                    inp = c.get("input", {}) or {}
                    summary["tool_calls"][name] += 1
                    if name in ("Edit", "Write", "NotebookEdit"):
                        path = inp.get("file_path") or inp.get("notebook_path") or ""
                        if path:
                            summary["files_edited"].add(path)
                    elif name == "Read":
                        path = inp.get("file_path", "")
                        if path:
                            summary["files_read"].add(path)
                    elif name == "Bash":
                        cmd = (inp.get("command") or "")[:120]
                        if cmd:
                            t = obj.get("timestamp", "")
                            summary["bash_cmds"].append((t, cmd))
                    elif name == "Agent":
                        desc = (inp.get("description") or "")[:120]
                        t = obj.get("timestamp", "")
                        summary["subagent_spawns"].append((t, desc))
        # Tool results — capture errors
        elif otype == "tool_result":
            content = obj.get("content")
            err = obj.get("is_error") or obj.get("error")
            if err and content:
                t = obj.get("timestamp", "")
                snip = (str(content)[:120]) if not isinstance(content, str) else content[:120]
                summary["errors"].append((t, snip))
    return summary


def write_agent_summary(agent: str, date_str: str, sessions: list[dict], jsonl_paths: list[str]) -> Path:
    """Aggregate per-session summaries into one daily file."""
    target_dir = MESH_ROOT / "agents" / agent / "transcripts"
    target_dir.mkdir(parents=True, exist_ok=True)
    out_path = target_dir / f"{date_str}-claude-code.md"

    total_user_asks = sum(len(s["user_asks"]) for s in sessions)
    total_tools = sum(sum(s["tool_calls"].values()) for s in sessions)
    all_tools = Counter()
    all_files_edited = set()
    all_files_read = set()
    all_bash = []
    all_subagents = []
    all_errors = []
    all_user_asks = []
    cwds = set()
    branches = set()
    models = set()

    for s in sessions:
        all_tools.update(s["tool_calls"])
        all_files_edited.update(s["files_edited"])
        all_files_read.update(s["files_read"])
        all_bash.extend(s["bash_cmds"])
        all_subagents.extend(s["subagent_spawns"])
        all_errors.extend(s["errors"])
        all_user_asks.extend(s["user_asks"])
        if s["cwd"]:
            cwds.add(s["cwd"])
        if s["git_branch"]:
            branches.add(s["git_branch"])
        if s["model"]:
            models.add(s["model"])

    # Sort by timestamp
    all_user_asks.sort(key=lambda x: x[0])
    all_bash.sort(key=lambda x: x[0])
    all_subagents.sort(key=lambda x: x[0])
    all_errors.sort(key=lambda x: x[0])

    body_lines = [
        "---",
        f"agent: {agent}@mesh",
        f"date: {date_str}",
        f"generated: {ts()}",
        f"source_jsonl_count: {len(jsonl_paths)}",
        f"session_count: {len(sessions)}",
        f"user_ask_count: {total_user_asks}",
        f"tool_call_count: {total_tools}",
        f"files_edited_count: {len(all_files_edited)}",
        f"files_read_count: {len(all_files_read)}",
        f"bash_command_count: {len(all_bash)}",
        f"subagent_spawn_count: {len(all_subagents)}",
        f"error_count: {len(all_errors)}",
        "---",
        "",
        f"# {agent} — Claude Code transcript summary {date_str}",
        "",
        f"**Sessions:** {len(sessions)} from {len(jsonl_paths)} jsonl file(s)  ",
        f"**Working dirs:** {', '.join(sorted(cwds)) or '-'}  ",
        f"**Git branches:** {', '.join(sorted(branches)) or '-'}  ",
        f"**Models:** {', '.join(sorted(models)) or '-'}",
        "",
        "## Tool usage",
        "",
    ]
    if all_tools:
        for name, count in all_tools.most_common():
            body_lines.append(f"- {name}: {count}")
    else:
        body_lines.append("- (no tool calls)")

    body_lines += ["", "## User asks", ""]
    if all_user_asks:
        for t, text in all_user_asks[:50]:
            body_lines.append(f"- `{t}` — {text}")
        if len(all_user_asks) > 50:
            body_lines.append(f"- ...and {len(all_user_asks) - 50} more")
    else:
        body_lines.append("- (no user asks captured)")

    body_lines += ["", "## Files edited (Edit/Write/NotebookEdit)", ""]
    if all_files_edited:
        for p in sorted(all_files_edited)[:200]:
            body_lines.append(f"- {p}")
        if len(all_files_edited) > 200:
            body_lines.append(f"- ...and {len(all_files_edited) - 200} more")
    else:
        body_lines.append("- (none)")

    body_lines += ["", "## Bash commands (first 100)", ""]
    if all_bash:
        for t, cmd in all_bash[:100]:
            body_lines.append(f"- `{t}` — `{cmd}`")
        if len(all_bash) > 100:
            body_lines.append(f"- ...and {len(all_bash) - 100} more")
    else:
        body_lines.append("- (none)")

    body_lines += ["", "## Sub-agent spawns", ""]
    if all_subagents:
        for t, desc in all_subagents:
            body_lines.append(f"- `{t}` — {desc}")
    else:
        body_lines.append("- (none)")

    body_lines += ["", "## Errors / failures", ""]
    if all_errors:
        for t, snip in all_errors[:50]:
            body_lines.append(f"- `{t}` — {snip}")
        if len(all_errors) > 50:
            body_lines.append(f"- ...and {len(all_errors) - 50} more")
    else:
        body_lines.append("- (none)")

    body_lines += ["", "## Files read (top 50)", ""]
    if all_files_read:
        for p in sorted(all_files_read)[:50]:
            body_lines.append(f"- {p}")
        if len(all_files_read) > 50:
            body_lines.append(f"- ...and {len(all_files_read) - 50} more")
    else:
        body_lines.append("- (none)")

    out_path.write_text("\n".join(body_lines) + "\n")
    return out_path


def main(date_str: str | None = None) -> int:
    if date_str is None:
        # default = yesterday UTC
        yesterday = _dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=1)
        date_str = yesterday.strftime("%Y-%m-%d")
    log(f"extract start for date {date_str}")

    summary_lines = ["", f"# Extraction summary — {date_str}", "",
                     "| Agent | Mode | jsonl files | sessions | user asks | tools | files edited | bash cmds | output |",
                     "|---|---|---|---|---|---|---|---|---|"]

    for agent, mode, target in AGENTS:
        log(f"  agent={agent} mode={mode} target={target}")
        jsonl_paths = list_jsonl_for_date(agent, mode, target, date_str)
        if not jsonl_paths:
            summary_lines.append(f"| {agent} | {mode} | 0 | 0 | 0 | 0 | 0 | 0 | (none) |")
            log(f"    no jsonl found")
            continue

        sessions = []
        for p in jsonl_paths:
            content = fetch_jsonl_content(mode, target, p)
            if not content:
                continue
            s = parse_session(content)
            sessions.append(s)

        out = write_agent_summary(agent, date_str, sessions, jsonl_paths)
        n_user = sum(len(s["user_asks"]) for s in sessions)
        n_tools = sum(sum(s["tool_calls"].values()) for s in sessions)
        n_edits = len({p for s in sessions for p in s["files_edited"]})
        n_bash = sum(len(s["bash_cmds"]) for s in sessions)
        summary_lines.append(
            f"| {agent} | {mode} | {len(jsonl_paths)} | {len(sessions)} | "
            f"{n_user} | {n_tools} | {n_edits} | {n_bash} | {out.relative_to(MESH_ROOT)} |"
        )
        log(f"    wrote {out} ({len(sessions)} sessions, {n_tools} tools)")

    # Stamp STATE_CHECK
    sc_dir = MESH_ROOT / "mesh" / "STATE_CHECK"
    sc_dir.mkdir(parents=True, exist_ok=True)
    sc_file = sc_dir / f"{_dt.datetime.now(_dt.timezone.utc).strftime('%Y-%m-%dT%H%M%SZ')}-host-transcript-extract-{date_str}.md"
    sc_file.write_text(
        f"## host@mesh @ {ts()}\n"
        f"- transcript-extract-date: {date_str}\n"
        f"- transcript-extract-agents: {len(AGENTS)}\n"
        + "\n".join(summary_lines) + "\n"
    )
    log(f"  STATE_CHECK stamped: {sc_file}")

    print("\n".join(summary_lines))
    log("extract complete")
    return 0


if __name__ == "__main__":
    arg_date = sys.argv[1] if len(sys.argv) > 1 else None
    sys.exit(main(arg_date))
