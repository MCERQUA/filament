#!/usr/bin/env python3
"""
generate.py — render a Filament mesh status dashboard from live state.

Reads:
  - tasks.yaml         registry of tracked work + detection rules
  - agents.yaml        agent identity + display config
  - $FILAMENT_REPO     git log to detect shipped commits
  - $MESH_ROOT         mesh state: HEARTBEAT, DECISIONS, BROADCAST, UPGRADES, inboxes
  - docker mounts      which containers have which mesh paths mounted
  - host crontab       which cron jobs are installed
  - template.html      string-substitution template with {{slots}}

Writes:
  $CANVAS_OUT          rendered HTML (default /var/www/filament-canvas/index.html)

Run via cron / systemd timer (every 15 min recommended).

Configuration (all overridable via env):
  MESH_ROOT          mesh root (default: /opt/filament-mesh)
  FILAMENT_REPO      tracked repo for git_commit detection (default: ~/filament)
  CANVAS_OUT         output path (default: /var/www/filament-canvas/index.html)
  CANVAS_TEMPLATE    template file (default: <script-dir>/template.html)
  CANVAS_TASKS       tasks.yaml (default: <script-dir>/tasks.yaml)
  CANVAS_AGENTS      agents.yaml (default: <script-dir>/agents.yaml)
  CANVAS_TITLE       page title (default: "Filament Mesh Intelligence")
  CANVAS_SUBTITLE    sidebar subtitle (default: derived from hostname)
"""
import os
import re
import sys
import json
import glob
import socket
import subprocess
import time
from pathlib import Path
from datetime import datetime, timezone

# --------------------------------------------------------------------- config
HERE = Path(__file__).parent
MESH_ROOT = Path(os.environ.get("MESH_ROOT", "/opt/filament-mesh"))
FILAMENT_REPO = Path(os.environ.get("FILAMENT_REPO", os.path.expanduser("~/filament")))
CANVAS_OUT = Path(os.environ.get("CANVAS_OUT", "/var/www/filament-canvas/index.html"))
TEMPLATE = Path(os.environ.get("CANVAS_TEMPLATE", str(HERE / "template.html")))
TASKS_YAML = Path(os.environ.get("CANVAS_TASKS", str(HERE / "tasks.yaml")))
AGENTS_YAML = Path(os.environ.get("CANVAS_AGENTS", str(HERE / "agents.yaml")))
PAGE_TITLE = os.environ.get("CANVAS_TITLE", "Filament Mesh Intelligence")
PAGE_SUBTITLE = os.environ.get("CANVAS_SUBTITLE", socket.gethostname())

# Status -> (badge class, dot class, label)
STATUS = {
    "live":        ("badge-green",  "dot-green",  "LIVE"),
    "in_progress": ("badge-amber",  "dot-amber",  "IN PROGRESS"),
    "planned":     ("badge-blue",   "dot-blue",   "PLANNED"),
    "blocked":     ("badge-red",    "dot-red",    "BLOCKED"),
    "rejected":    ("badge-red",    "dot-dim",    "REJECTED"),
    "gap":         ("badge-amber",  "dot-amber",  "GAP"),
    "vuln":        ("badge-red",    "dot-red",    "VULN"),
}

# --------------------------------------------------------------------- yaml
def load_yaml(p):
    """Minimal YAML loader. Uses PyYAML if available, else shells out."""
    try:
        import yaml
        return yaml.safe_load(p.read_text())
    except ImportError:
        out = subprocess.check_output([
            "python3", "-c",
            f"import yaml,sys,json; print(json.dumps(yaml.safe_load(open('{p}').read())))"
        ])
        return json.loads(out)

# --------------------------------------------------------------------- detection
def _resolve_repo(name):
    """Map symbolic repo name to a Path."""
    if name == "filament":
        return FILAMENT_REPO
    return Path(os.path.expanduser(name))

def _docker_cmd(args):
    """Run docker, falling back to `sg docker -c` for non-root callers in the docker group."""
    try:
        return subprocess.check_output(["docker", *args],
            stderr=subprocess.DEVNULL, text=True, timeout=10)
    except (FileNotFoundError, subprocess.CalledProcessError):
        try:
            return subprocess.check_output(
                ["sg", "docker", "-c", "docker " + " ".join(args)],
                stderr=subprocess.DEVNULL, text=True, timeout=10)
        except Exception:
            return ""

def detect_status(task):
    """Resolve a task's status from its detect rule."""
    d = task.get("detect", {})
    t = d.get("type")
    try:
        if t == "file_exists":
            return "live" if Path(os.path.expanduser(d["path"])).exists() else "planned"

        if t == "dir_exists":
            return "live" if Path(os.path.expanduser(d["path"])).is_dir() else "planned"

        if t == "git_commit":
            repo = _resolve_repo(d["repo"])
            if not repo.exists():
                return "planned"
            log = subprocess.check_output(
                ["git", "-C", str(repo), "log", "--oneline", "-200"],
                stderr=subprocess.DEVNULL, text=True
            )
            return "live" if re.search(d["subject_match"], log) else "planned"

        if t == "container_mount":
            ok = 0
            fmt = '{{range .Mounts}}{{if eq .Destination "%s"}}{{.Mode}}{{end}}{{end}}' % d["path"]
            for c in d["containers"]:
                out = _docker_cmd(["inspect", c, "--format", fmt]).strip()
                if out:
                    ok += 1
            if ok == len(d["containers"]):
                return "live"
            if ok > 0:
                return "in_progress"
            return "planned"

        if t == "file_exists_in_container":
            out = _docker_cmd(["exec", d["container"], "test", "-f", d["path"]])
            return "live" if out is not None and out != "" or _container_test_passed(d) else _check_file_exec(d)

        if t == "glob":
            return "live" if glob.glob(os.path.expanduser(d["path"])) else "planned"

        if t == "file_contains":
            p = Path(os.path.expanduser(d["path"]))
            if p.exists() and d["text"] in p.read_text():
                return "live"
            return "planned"

        if t == "cron_present":
            try:
                out = subprocess.run(["crontab", "-l"], capture_output=True, text=True, timeout=5)
                user_cron = out.stdout if out.returncode == 0 else ""
                cd = ""
                cd_dir = Path("/etc/cron.d")
                if cd_dir.exists():
                    for f in cd_dir.iterdir():
                        try:
                            cd += f.read_text()
                        except Exception:
                            pass
                if d["pattern"] in (user_cron + cd):
                    return "live"
                return "planned"
            except Exception:
                return "planned"

        if t == "systemd_timer":
            try:
                out = subprocess.check_output(
                    ["systemctl", "list-timers", "--all", "--no-legend"],
                    stderr=subprocess.DEVNULL, text=True, timeout=5
                )
                return "live" if d["unit"] in out else "planned"
            except Exception:
                return "planned"

    except Exception as e:
        print(f"  [warn] detection failed for {task.get('id')}: {e}", file=sys.stderr)
    return "planned"


def _check_file_exec(d):
    """Helper: check a file exists inside a container (separate to avoid throwing in main path)."""
    try:
        subprocess.check_output(
            ["docker", "exec", d["container"], "test", "-f", d["path"]],
            stderr=subprocess.DEVNULL, timeout=10
        )
        return "live"
    except Exception:
        try:
            subprocess.check_output(
                ["sg", "docker", "-c", f"docker exec {d['container']} test -f {d['path']}"],
                stderr=subprocess.DEVNULL, timeout=10
            )
            return "live"
        except Exception:
            return "planned"


def _container_test_passed(d):
    return False  # always falls through to the explicit checker

# --------------------------------------------------------------------- mesh state
def mesh_state():
    """Snapshot of live mesh stats."""
    state = {
        "host_inbox_unread": 0,
        "host_inbox_read": 0,
        "decisions": 0,
        "broadcasts": 0,
        "upgrades_logged": 0,
        "agent_liveness": {},
        "filament_commits": [],
    }
    host_inbox = MESH_ROOT / "agents/host/inbox"
    if host_inbox.exists():
        state["host_inbox_unread"] = len([p for p in host_inbox.iterdir() if p.is_file() and p.suffix == ".md"])
        read_dir = host_inbox / ".read"
        if read_dir.exists():
            state["host_inbox_read"] = len([p for p in read_dir.iterdir() if p.is_file() and p.suffix == ".md"])

    for sub, key in [("DECISIONS", "decisions"), ("BROADCAST", "broadcasts"), ("UPGRADES", "upgrades_logged")]:
        d = MESH_ROOT / "mesh" / sub
        if d.exists():
            state[key] = len(list(d.glob("*.md")))

    hb_dir = MESH_ROOT / "mesh/HEARTBEAT"
    if hb_dir.exists():
        now = time.time()
        for f in hb_dir.glob("*.last"):
            age = now - f.stat().st_mtime
            agent = f.stem
            if age < 900:        state["agent_liveness"][agent] = "live"
            elif age < 3600:     state["agent_liveness"][agent] = "stale"
            else:                state["agent_liveness"][agent] = "offline"

    if FILAMENT_REPO.exists() and (FILAMENT_REPO / ".git").exists():
        try:
            log = subprocess.check_output(
                ["git", "-C", str(FILAMENT_REPO), "log", "--oneline", "-15"],
                text=True
            ).strip().splitlines()
            state["filament_commits"] = log
        except Exception:
            pass

    return state

# --------------------------------------------------------------------- rendering
def render_agent_cards(agents, liveness):
    html = []
    for a in agents:
        uri = a["uri"]
        agent_name = uri.split("@")[0]
        live = liveness.get(agent_name, "unknown")
        if a.get("is_intermittent"):
            dot, label = "dot-amber", "intermittent"
        elif live == "live":
            dot, label = "dot-green", "live"
        elif live == "stale":
            dot, label = "dot-amber", "stale"
        elif live == "offline":
            dot, label = "dot-red", "offline"
        else:
            dot, label = "dot-dim", "unknown"

        border = ""
        if a.get("is_central"):
            border = "border-color:var(--blue);"
        elif a.get("is_intermittent"):
            border = "border-style:dashed;"

        name_color = "color:var(--blue)" if a.get("is_central") else (
            "color:var(--text-dim)" if a.get("is_intermittent") else "")

        role = a.get("role", "")
        description = a.get("description", "")

        html.append(f"""<div class="agent-card" style="{border}">
  <div class="agent-status"><span class="dot {dot}"></span> {label}</div>
  <div class="agent-name" style="{name_color}">{uri}</div>
  <div class="agent-role" style="font-weight:600;color:var(--text);margin-top:2px">{role or '&mdash;'}</div>
  <div style="margin-top:0.6rem;font-size:0.72rem;color:var(--text-muted);line-height:1.45">{description}</div>
</div>""")
    return "\n".join(html) or '<div style="color:var(--text-dim);font-size:0.78rem">No agents configured. Edit <code>agents.yaml</code> and add an entry.</div>'

def render_status_table(tasks):
    rows = []
    for t in tasks:
        status = detect_status(t)
        if status == "planned" and t.get("severity") == "critical":
            status = "vuln"
        badge_class, _, label = STATUS[status]
        rows.append(f"""<tr>
  <td class="mono" style="font-size:0.75rem">{t['name']}</td>
  <td>{t.get('layer','&mdash;')}</td>
  <td>{t.get('owner','&mdash;')}</td>
  <td>{t.get('sprint','&mdash;')}</td>
  <td><span class="badge {badge_class}">{label}</span></td>
  <td style="font-size:0.72rem;color:var(--text-muted)">{t.get('notes','')}</td>
</tr>""")
    return "\n".join(rows) or '<tr><td colspan="6" style="color:var(--text-dim);font-size:0.78rem">No tasks defined. Add entries to <code>tasks.yaml</code>.</td></tr>'

def status_summary(tasks):
    counts = {"live": 0, "in_progress": 0, "planned": 0, "blocked": 0, "vuln": 0, "rejected": 0, "gap": 0}
    for t in tasks:
        s = detect_status(t)
        if s == "planned" and t.get("severity") == "critical":
            s = "vuln"
        counts[s] = counts.get(s, 0) + 1
    return counts

def render_recent_commits(commits):
    rows = []
    for line in commits[:8]:
        if " " in line:
            sha, _, subj = line.partition(" ")
            rows.append(f'<div style="font-family:Fira Code,monospace;font-size:0.72rem;padding:0.35rem 0;border-bottom:1px solid var(--border)"><span style="color:var(--green)">{sha}</span> <span style="color:var(--text-muted)">{subj}</span></div>')
    return "\n".join(rows) or '<div style="color:var(--text-dim);font-size:0.75rem">No commits in tracked repo (set FILAMENT_REPO env to a git checkout).</div>'

# --------------------------------------------------------------------- main
def main():
    if not TEMPLATE.exists():
        print(f"FATAL: template not found at {TEMPLATE}", file=sys.stderr)
        sys.exit(1)
    if not TASKS_YAML.exists():
        print(f"FATAL: tasks.yaml not found at {TASKS_YAML}", file=sys.stderr)
        sys.exit(1)
    if not AGENTS_YAML.exists():
        print(f"FATAL: agents.yaml not found at {AGENTS_YAML}", file=sys.stderr)
        sys.exit(1)

    tasks_doc = load_yaml(TASKS_YAML) or {}
    agents_doc = load_yaml(AGENTS_YAML) or {}
    tasks = tasks_doc.get("tasks", [])
    agents = agents_doc.get("agents", [])

    state = mesh_state()
    counts = status_summary(tasks)
    now_utc = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    slots = {
        "{{PAGE_TITLE}}": PAGE_TITLE,
        "{{PAGE_SUBTITLE}}": PAGE_SUBTITLE,
        "{{LAST_GENERATED}}": now_utc,
        "{{COUNT_LIVE}}": str(counts.get("live", 0)),
        "{{COUNT_IN_PROGRESS}}": str(counts.get("in_progress", 0)),
        "{{COUNT_PLANNED}}": str(counts.get("planned", 0)),
        "{{COUNT_VULN}}": str(counts.get("vuln", 0)),
        "{{COUNT_BLOCKED}}": str(counts.get("blocked", 0)),
        "{{HOST_INBOX_UNREAD}}": str(state["host_inbox_unread"]),
        "{{HOST_INBOX_READ}}": str(state["host_inbox_read"]),
        "{{DECISIONS_COUNT}}": str(state["decisions"]),
        "{{BROADCASTS_COUNT}}": str(state["broadcasts"]),
        "{{UPGRADES_COUNT}}": str(state["upgrades_logged"]),
        "{{AGENT_CARDS}}": render_agent_cards(agents, state["agent_liveness"]),
        "{{STATUS_TABLE_ROWS}}": render_status_table(tasks),
        "{{RECENT_COMMITS}}": render_recent_commits(state["filament_commits"]),
        "{{MESH_ROOT}}": str(MESH_ROOT),
        "{{FILAMENT_REPO}}": str(FILAMENT_REPO),
    }

    template = TEMPLATE.read_text()
    output = template
    for k, v in slots.items():
        output = output.replace(k, v)

    CANVAS_OUT.parent.mkdir(parents=True, exist_ok=True)
    tmp = CANVAS_OUT.with_suffix(CANVAS_OUT.suffix + ".tmp")
    tmp.write_text(output)
    tmp.replace(CANVAS_OUT)

    print(f"+ canvas regenerated at {CANVAS_OUT}")
    print(f"  live={counts['live']}  in_progress={counts['in_progress']}  planned={counts['planned']}  vuln={counts['vuln']}")
    print(f"  inbox unread={state['host_inbox_unread']}  decisions={state['decisions']}  upgrades={state['upgrades_logged']}")

if __name__ == "__main__":
    main()
