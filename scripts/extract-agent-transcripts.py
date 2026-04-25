#!/usr/bin/env python3
"""
extract-agent-transcripts.py — v2

Pulls Claude Code session transcripts from every mesh agent and extracts
a daily REFLECTION-READY recap (not a raw histogram dump).

Why v2: openclaw already has its own voice/conversation reflection. This
extractor's audience is the mesh nightly group synthesis — agents need to
re-read their own day's WORK and surface problems, realizations, learnings.
A bash-command trace doesn't help; a turn-by-turn recap with pivot moments
and error→recovery sequences does.

Output schema (per agent, per day):

    ---
    frontmatter (counts + day-summary stats)
    ---
    # <agent> — Claude Code recap <DATE>

    ## Day at a glance (one paragraph)
    ## Files touched (per-file purpose + edit count)
    ## Turn-by-turn (compressed)        ← user ask + agent reasoning + tools
    ## Pivot moments (user corrections)
    ## Problems & recoveries (error → next-action)
    ## Tool usage (histogram, abbreviated)

Targets <30 KB per agent per day. Caps every section.

Schedule: 03:00 UTC daily, 15 min before mesh-nightly-kickoff (03:15).
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

AGENTS = [
    ("bun-desktop",        "docker", "webtop-ubuntu-os"),
    ("josh-desktop",       "docker", "webtop-ubuntu-os-josh"),
    ("danielle-desktop",   "docker", "webtop-ubuntu-os-danielle"),
    ("src-desktop",        "docker", "webtop-ubuntu-os-src"),
    ("host",               "local",  "/home/mike/.claude/projects"),
    ("residential-laptop", "ssh",    "residential-laptop"),
]

DOCKER_CC = "/config/.claude/projects"
LAPTOP_CC = "/root/.claude/projects"

# Pivot indicators in user text — moments where the user corrected, redirected,
# or expressed dissatisfaction. These mark important learning beats.
PIVOT_PATTERNS = [
    r"\b(no|nope|wrong|stop|wait|don't|do not|incorrect|that'?s not)\b",
    r"\b(actually|instead|rather|let'?s try|try (again|something))\b",
    r"\bdifferent (approach|way|method)\b",
    r"\bredo\b",
    r"\bthat'?s wrong\b",
    r"\bnot (what|the way|right)\b",
    r"^\s*(no|nope|wrong)\b",
    r"why (didn'?t|don'?t|isn'?t|are|is)\b",  # questioning intent
    r"^[^a-z]*(no|nope|stop|wait|wrong)[!.]?\s*$",
]
PIVOT_RE = re.compile("|".join(PIVOT_PATTERNS), re.IGNORECASE)


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


def trunc(s: str, head: int = 240, tail: int = 0) -> str:
    s = (s or "").strip().replace("\n", " ").replace("  ", " ")
    if len(s) <= head + tail:
        return s
    if tail > 0:
        return f"{s[:head]} … {s[-tail:]}"
    return s[:head] + "…"


def list_jsonl_for_date(agent: str, mode: str, target: str, date_str: str) -> list[str]:
    if mode == "local":
        root = Path(target)
        if not root.is_dir():
            return []
        out = []
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
        rc, stdout, _ = run([
            "docker", "exec", target, "bash", "-c",
            f"find {DOCKER_CC} -name '*.jsonl' -newermt '{date_str} 00:00:00' "
            f"! -newermt '{date_str} 23:59:59' 2>/dev/null"
        ], timeout=60)
        return [l.strip() for l in stdout.splitlines() if l.strip()] if rc == 0 else []
    elif mode == "ssh":
        rc, stdout, _ = run([
            "ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes",
            target, "bash", "-c",
            f"find {LAPTOP_CC} -name '*.jsonl' -newermt '{date_str} 00:00:00' "
            f"! -newermt '{date_str} 23:59:59' 2>/dev/null"
        ], timeout=15)
        return [l.strip() for l in stdout.splitlines() if l.strip()] if rc == 0 else []
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


def classify_user_text(text: str) -> str:
    """Returns: 'human', 'slash', 'bootstrap', or 'noise'.
    'human' = real human prose. 'slash' = slash-command body. 'bootstrap' =
    autonomous-session prompt template. 'noise' = filter out."""
    if not text or len(text) < 15:
        return "noise"
    t = text.lstrip()
    if t.startswith("<system-reminder>"):
        return "noise"
    if t.startswith("<task-notification>"):
        return "noise"
    if t.startswith("<bash-stdout>") or t.startswith("<bash-stderr>"):
        return "noise"
    if t.startswith("Tool result:") or t.startswith("[tool result]"):
        return "noise"
    if "user-prompt-submit-hook" in t[:200]:
        return "noise"
    if t.startswith("<local-command-caveat>"):
        # may contain a real human prompt after the caveat block
        # find the actual prompt (after the closing tag)
        end = t.find("</local-command-caveat>")
        if end > 0 and len(t) > end + 30:
            return "human"
        return "noise"
    if t.startswith("<command-name>") or t.startswith("<command-message>"):
        return "slash"
    if t.startswith("The user invoked `/"):
        return "slash"
    if re.match(r"^You are \S+@mesh\.?", t):
        return "bootstrap"
    return "human"


def is_real_user_text(text: str) -> bool:
    """Backwards-compat shim — returns True for human/slash/bootstrap."""
    return classify_user_text(text) != "noise"


def extract_assistant_text(content) -> str:
    """Pull all text blocks from an assistant content array, joined."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for c in content:
        if isinstance(c, dict) and c.get("type") == "text":
            parts.append(c.get("text", ""))
    return " ".join(parts).strip()


def parse_session(jsonl_text: str) -> dict:
    """Build a turn-aligned timeline + structured rollups."""
    summary = {
        "turns": [],            # list of dicts: {ts, user_ask, agent_text, tool_calls, edited_files, errors_in_turn}
        "tool_calls_total": Counter(),
        "files_edited": defaultdict(list),  # path -> [(turn_idx, ts)]
        "files_read": Counter(),
        "session_ids": set(),
        "model": None,
        "cwds": set(),
        "git_branches": set(),
        "errors": [],            # list of (ts, brief, surrounding_turn_idx)
        "pivots": [],            # list of (ts, user_text, turn_idx)
    }
    current_turn = None  # accumulating turn dict

    def flush_turn():
        nonlocal current_turn
        if current_turn is not None:
            summary["turns"].append(current_turn)
            current_turn = None

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
        if "cwd" in obj and obj.get("cwd"):
            summary["cwds"].add(obj["cwd"])
        if "gitBranch" in obj and obj.get("gitBranch"):
            summary["git_branches"].add(obj["gitBranch"])

        otype = obj.get("type")
        otime = obj.get("timestamp", "")

        if otype == "user":
            msg = obj.get("message", {})
            content = msg.get("content")
            text_parts = []
            if isinstance(content, str):
                text_parts.append(content)
            elif isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "text":
                        text_parts.append(c.get("text", ""))
            text = " ".join(text_parts).strip()

            kind = classify_user_text(text)
            if kind == "noise":
                continue

            # Start new turn
            flush_turn()
            current_turn = {
                "ts": otime,
                "user_ask": text,
                "user_kind": kind,
                "agent_text": "",
                "tool_calls": [],
                "edited_files": [],
                "errors_in_turn": [],
            }
            # Pivot detection — only fire on HUMAN turns (not slash/bootstrap)
            # AND only when the text is short enough to be a genuine reaction
            # (real pivots are < 500 chars; long messages are usually new asks)
            if kind == "human" and len(text) < 500 and PIVOT_RE.search(text[:300]):
                summary["pivots"].append((otime, text, len(summary["turns"])))

        elif otype == "assistant":
            msg = obj.get("message", {})
            if not summary["model"] and msg.get("model"):
                summary["model"] = msg["model"]

            text = extract_assistant_text(msg.get("content", []))
            if current_turn is not None and text:
                # accumulate (one turn may have multiple assistant messages)
                if current_turn["agent_text"]:
                    current_turn["agent_text"] += " | " + text
                else:
                    current_turn["agent_text"] = text

            for c in msg.get("content", []) or []:
                if not isinstance(c, dict) or c.get("type") != "tool_use":
                    continue
                name = c.get("name", "")
                inp = c.get("input", {}) or {}
                summary["tool_calls_total"][name] += 1

                tc = {"ts": otime, "name": name}
                if name in ("Edit", "Write", "NotebookEdit"):
                    path = inp.get("file_path") or inp.get("notebook_path") or ""
                    if path:
                        summary["files_edited"][path].append((len(summary["turns"]), otime))
                        if current_turn is not None:
                            current_turn["edited_files"].append(path)
                        tc["path"] = path
                elif name == "Read":
                    path = inp.get("file_path", "")
                    if path:
                        summary["files_read"][path] += 1
                        tc["path"] = path
                elif name == "Bash":
                    tc["cmd"] = trunc(inp.get("command", ""), 100)
                    tc["desc"] = trunc(inp.get("description", ""), 80)
                elif name == "Agent":
                    tc["desc"] = trunc(inp.get("description", ""), 100)
                elif name in ("Grep", "Glob"):
                    tc["pattern"] = trunc(inp.get("pattern", "") or inp.get("path", ""), 80)

                if current_turn is not None:
                    current_turn["tool_calls"].append(tc)

        elif otype == "tool_result":
            err = obj.get("is_error") or obj.get("error")
            if err:
                content = obj.get("content")
                snip = trunc(str(content) if not isinstance(content, str) else content, 140)
                turn_idx = len(summary["turns"])
                summary["errors"].append((otime, snip, turn_idx))
                if current_turn is not None:
                    current_turn["errors_in_turn"].append(snip)

    flush_turn()
    return summary


def write_agent_recap(agent: str, date_str: str, sessions: list[dict], jsonl_paths: list[str]) -> Path:
    target_dir = MESH_ROOT / "agents" / agent / "transcripts"
    target_dir.mkdir(parents=True, exist_ok=True)
    out_path = target_dir / f"{date_str}-claude-code.md"

    # Aggregate
    all_turns = []
    all_pivots = []
    all_errors = []
    all_tools = Counter()
    all_files_edited = defaultdict(int)
    all_files_read = Counter()
    cwds = set()
    branches = set()
    models = set()

    for s in sessions:
        all_turns.extend(s["turns"])
        all_pivots.extend(s["pivots"])
        all_errors.extend(s["errors"])
        all_tools.update(s["tool_calls_total"])
        for path, hits in s["files_edited"].items():
            all_files_edited[path] += len(hits)
        all_files_read.update(s["files_read"])
        cwds.update(s["cwds"])
        branches.update(s["git_branches"])
        if s["model"]:
            models.add(s["model"])

    # Sort turns by timestamp
    all_turns.sort(key=lambda t: t.get("ts", ""))
    all_pivots.sort(key=lambda x: x[0])
    all_errors.sort(key=lambda x: x[0])

    # ---- Day at a glance — one paragraph synthetic recap ----
    n_turns = len(all_turns)
    n_files = len(all_files_edited)
    n_pivots = len(all_pivots)
    n_errors = len(all_errors)
    top_tools = ", ".join(f"{n}({c})" for n, c in all_tools.most_common(4))
    # Count human/slash/bootstrap turns separately
    human_turns = [t for t in all_turns if t.get("user_kind") == "human"]
    slash_turns = [t for t in all_turns if t.get("user_kind") == "slash"]
    boot_turns  = [t for t in all_turns if t.get("user_kind") == "bootstrap"]

    if n_turns == 0:
        glance = "No real user turns captured today (only system reminders / hook noise)."
    else:
        # Prefer human turns for opened/closed-with quotes
        opener_pool = human_turns or all_turns
        closer_pool = human_turns or all_turns
        first_ask = trunc(opener_pool[0].get("user_ask", ""), 120)
        last_ask = trunc(closer_pool[-1].get("user_ask", ""), 120) if len(closer_pool) > 1 else ""
        breakdown = []
        if human_turns: breakdown.append(f"{len(human_turns)} human")
        if slash_turns: breakdown.append(f"{len(slash_turns)} slash")
        if boot_turns:  breakdown.append(f"{len(boot_turns)} bootstrap")
        glance = (
            f"{n_turns} turns ({', '.join(breakdown)}) producing "
            f"{n_files} file edit{'s' if n_files != 1 else ''}, "
            f"{n_pivots} pivot{'s' if n_pivots != 1 else ''}, "
            f"{n_errors} error{'s' if n_errors != 1 else ''}. "
            f"Top tools: {top_tools}. "
            f"Day opened with: \"{first_ask}\""
        )
        if last_ask and last_ask != first_ask:
            glance += f" Closed with: \"{last_ask}\""

    # ---- Files touched — per-file purpose ----
    file_lines = []
    if all_files_edited:
        # for each file, find the first user ask that mentioned an edit pointing here
        for path, count in sorted(all_files_edited.items(), key=lambda x: -x[1])[:30]:
            # find the first turn that edited this file
            purpose = ""
            for t in all_turns:
                if path in t.get("edited_files", []):
                    purpose = trunc(t.get("user_ask", ""), 100)
                    break
            if not purpose:
                purpose = "(no user-ask context found)"
            file_lines.append(f"- `{path}` — {count} edit{'s' if count != 1 else ''}; purpose: {purpose}")
        if len(all_files_edited) > 30:
            file_lines.append(f"- …and {len(all_files_edited) - 30} more edited files")
    else:
        file_lines.append("- (no files edited)")

    # ---- Turn-by-turn (compressed) ----
    turn_lines = []
    # cap at 40 most informative turns: those with edits, errors, or pivots get priority
    if all_turns:
        important = [
            (i, t) for i, t in enumerate(all_turns)
            if t.get("edited_files") or t.get("errors_in_turn") or t.get("tool_calls")
        ]
        if not important:
            important = list(enumerate(all_turns))
        cap = 40
        if len(important) > cap:
            # take first 5, last 5, and middle samples
            samples = important[:5] + important[-5:]
            # plus turns with pivots
            pivot_idx = {p[2] for p in all_pivots}
            for i, t in important[5:-5]:
                if i in pivot_idx:
                    samples.append((i, t))
            samples = sorted(set([s[0] for s in samples]))[:cap]
            important = [(i, all_turns[i]) for i in samples]

        for idx, t in important:
            ts_str = t.get("ts", "")[:19]
            ask = trunc(t.get("user_ask", ""), 200)
            agent_text = trunc(t.get("agent_text", ""), 220, tail=80)
            tools = t.get("tool_calls", [])
            pivot_marker = " [PIVOT]" if any(p[2] == idx for p in all_pivots) else ""
            err_marker = f" [ERR×{len(t['errors_in_turn'])}]" if t.get("errors_in_turn") else ""

            turn_lines.append(f"### {ts_str}{pivot_marker}{err_marker}")
            turn_lines.append(f"**[user]** {ask}")
            if agent_text:
                turn_lines.append(f"**[agent]** {agent_text}")
            if tools:
                tool_summary = []
                bash_count = sum(1 for x in tools if x["name"] == "Bash")
                edit_count = sum(1 for x in tools if x["name"] in ("Edit", "Write"))
                if bash_count:
                    tool_summary.append(f"Bash×{bash_count}")
                if edit_count:
                    tool_summary.append(f"Edit×{edit_count}")
                # show 1-2 representative bash commands
                bash_samples = [x for x in tools if x["name"] == "Bash"][:2]
                for b in bash_samples:
                    tool_summary.append(f"`{b.get('cmd', '')}`")
                tool_summary.extend(
                    f"{x['name']}({x.get('path') or x.get('desc') or ''})"[:80]
                    for x in tools
                    if x["name"] not in ("Bash", "Edit", "Write")
                )
                turn_lines.append(f"**[tools]** {', '.join(tool_summary[:6])}")
            if t.get("errors_in_turn"):
                turn_lines.append(f"**[error]** {t['errors_in_turn'][0]}")
            turn_lines.append("")
    else:
        turn_lines.append("(no real user turns)")

    # ---- Pivot moments ----
    pivot_lines = []
    if all_pivots:
        for ts_str, text, idx in all_pivots[:15]:
            pivot_lines.append(f"- `{ts_str[:19]}` — {trunc(text, 200)}")
        if len(all_pivots) > 15:
            pivot_lines.append(f"- …and {len(all_pivots) - 15} more pivots")
    else:
        pivot_lines.append("- (no pivots — agent stayed on track)")

    # ---- Problems & recoveries ----
    err_lines = []
    if all_errors:
        for ts_str, snip, turn_idx in all_errors[:20]:
            # find the next user ask after this error → that's often the recovery prompt
            recovery = ""
            for t in all_turns:
                if t.get("ts", "") > ts_str:
                    recovery = trunc(t.get("user_ask", ""), 150)
                    break
            line = f"- `{ts_str[:19]}` — {snip}"
            if recovery:
                line += f"\n  → followup: {recovery}"
            err_lines.append(line)
        if len(all_errors) > 20:
            err_lines.append(f"- …and {len(all_errors) - 20} more errors")
    else:
        err_lines.append("- (no errors — clean run)")

    # ---- Body assembly ----
    body = [
        "---",
        f"agent: {agent}@mesh",
        f"date: {date_str}",
        f"generated: {ts()}",
        f"schema_version: 2",
        f"source_jsonl_count: {len(jsonl_paths)}",
        f"session_count: {len(sessions)}",
        f"turn_count: {n_turns}",
        f"file_edit_count: {n_files}",
        f"pivot_count: {n_pivots}",
        f"error_count: {n_errors}",
        f"tool_call_count: {sum(all_tools.values())}",
        "---",
        "",
        f"# {agent} — Claude Code recap {date_str}",
        "",
        "## Day at a glance",
        "",
        glance,
        "",
        f"**Working dirs:** {', '.join(sorted(cwds)) or '-'}  ",
        f"**Git branches:** {', '.join(sorted(branches)) or '-'}  ",
        f"**Models:** {', '.join(sorted(models)) or '-'}",
        "",
        "## Files touched",
        "",
        *file_lines,
        "",
        "## Pivot moments (user corrections)",
        "",
        *pivot_lines,
        "",
        "## Problems & recoveries",
        "",
        *err_lines,
        "",
        "## Turn-by-turn",
        "",
        *turn_lines,
        "",
        "## Tool usage",
        "",
    ]
    if all_tools:
        for name, count in all_tools.most_common(15):
            body.append(f"- {name}: {count}")
    else:
        body.append("- (no tool calls)")

    out_path.write_text("\n".join(body) + "\n")
    return out_path


def main(date_str: str | None = None) -> int:
    if date_str is None:
        yesterday = _dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=1)
        date_str = yesterday.strftime("%Y-%m-%d")
    log(f"v2 extract start for date {date_str}")

    summary_lines = ["", f"# v2 Extraction summary — {date_str}", "",
                     "| Agent | Mode | jsonl | sessions | turns | files | pivots | errors | output kB |",
                     "|---|---|---|---|---|---|---|---|---|"]

    for agent, mode, target in AGENTS:
        log(f"  agent={agent} mode={mode}")
        jsonl_paths = list_jsonl_for_date(agent, mode, target, date_str)
        if not jsonl_paths:
            summary_lines.append(f"| {agent} | {mode} | 0 | 0 | 0 | 0 | 0 | 0 | - |")
            continue

        sessions = []
        for p in jsonl_paths:
            content = fetch_jsonl_content(mode, target, p)
            if not content:
                continue
            sessions.append(parse_session(content))

        out = write_agent_recap(agent, date_str, sessions, jsonl_paths)
        n_turns = sum(len(s["turns"]) for s in sessions)
        n_files = len({p for s in sessions for p in s["files_edited"]})
        n_pivots = sum(len(s["pivots"]) for s in sessions)
        n_errors = sum(len(s["errors"]) for s in sessions)
        size_kb = out.stat().st_size // 1024
        summary_lines.append(
            f"| {agent} | {mode} | {len(jsonl_paths)} | {len(sessions)} | "
            f"{n_turns} | {n_files} | {n_pivots} | {n_errors} | {size_kb} |"
        )
        log(f"    wrote {out} ({n_turns} turns, {n_pivots} pivots, {n_errors} errors, {size_kb}KB)")

    sc_dir = MESH_ROOT / "mesh" / "STATE_CHECK"
    sc_dir.mkdir(parents=True, exist_ok=True)
    sc_file = sc_dir / f"{_dt.datetime.now(_dt.timezone.utc).strftime('%Y-%m-%dT%H%M%SZ')}-host-transcript-extract-v2-{date_str}.md"
    sc_file.write_text(
        f"## host@mesh @ {ts()}\n"
        f"- transcript-extract-v2-date: {date_str}\n"
        f"- transcript-extract-v2-agents: {len(AGENTS)}\n"
        + "\n".join(summary_lines) + "\n"
    )

    print("\n".join(summary_lines))
    log("v2 extract complete")
    return 0


if __name__ == "__main__":
    arg_date = sys.argv[1] if len(sys.argv) > 1 else None
    sys.exit(main(arg_date))
