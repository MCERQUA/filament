#!/usr/bin/env python3
"""
render-guard.py — Claude Code PreToolUse hook (matcher: Bash). BLOCKING. This node does not render video.

WHY A BLOCKING HOOK
-------------------
Video rendering (remotion, hyperframes, headless-Chrome screenshot/PDF, ffmpeg synthetic or
frame-sequence encodes) will saturate a shared host that also serves live agents. When a
fleet has a dedicated render node (a Mac, a GPU box) the rule is "route renders there" — but
that rule, written as prose into an agent's instructions, is not a guard: prose addressed to
the model it constrains gets skipped the first time the model decides it is quicker to render
locally. Measured on the deployment this came from: the render toolchain was installed inside
every agent image, every exec lane was unbounded, and the existing PreToolUse hooks were
advisory by their own docstrings. So this one blocks.

BEHAVIOUR: reads the hook JSON on stdin ONLY (never shells out, never reads files — a test copy
of a hook that touches absolute paths writes to the live ones), matches the command against
RENDER verbs, and on a match prints ONE line to stderr and exits 2 (Claude Code: block the tool
call, show stderr to the model). Everything else exits 0 silently.

Bypass for a HUMAN at the shell, one command: prefix FILAMENT_RENDER_ALLOWED=1 in the command's
own env (a prior session's instruction is not that).

CONFIG (env, read at hook time):
    RENDER_GUARD_HANDOFF_URI   mesh URI renders are routed to   (default: gpu-node@mesh)
    RENDER_GUARD_CONTRACT      optional path to a handoff contract doc, named in the message

Register (Claude Code settings.json — submesh-launch and new-agent write this for you):
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command",
                    "command": "python3 <mesh-tools-bin>/render-guard.py"}]}]

Negative control (must block):
    echo '{"tool_input":{"command":"npx remotion render src/index.ts Main out.mp4"}}' | python3 render-guard.py; echo rc=$?   -> rc=2
Positive controls (must pass):
    ls remotion-project · mesh-send ... --subject 'remotion promo' · ffmpeg -i in.wav -ar 16000 out.wav · mmdc
Self-test:  python3 render-guard.py --self-test
"""
from __future__ import annotations
import json, os, re, sys


def _handoff() -> str:
    uri = os.environ.get("RENDER_GUARD_HANDOFF_URI", "gpu-node@mesh")
    contract = os.environ.get("RENDER_GUARD_CONTRACT", "")
    per = f" per {contract}" if contract else ""
    return (f"render-guard: this node does not render video. Hand the job to {uri} — "
            f"mesh-send --to {uri} --kind task{per} "
            "(engine and node choice are the render node's call). "
            "A human at the shell may prefix FILAMENT_RENDER_ALLOWED=1 for ONE command.")


PATTERNS = [
    # remotion / hyperframes render verbs, however invoked (npx, pnpm exec/dlx, direct, node .bin)
    (re.compile(r"(?<![\w/.-])(?:npx\s+(?:--yes\s+)?|pnpm\s+(?:exec|dlx)\s+|yarn\s+|bunx\s+)?(?:@remotion/cli\S*|remotion(?:b|d)?)(?:@\S+)?\s+(?:render|still|lambda|studio|benchmark|compositions)\b"), "remotion render verb"),
    (re.compile(r"node_modules/\.bin/remotion\b|@remotion/(?:renderer|cli|bundler)"), "remotion toolchain path"),
    # hyperframes as a COMMAND (start of command / after ; & | ( or a runner), never as a path segment —
    # the first version matched `ls .../bin/hyperframes`.
    (re.compile(r"(?:^|[;&|(])\s*(?:npx\s+(?:--yes\s+)?|pnpm\s+(?:exec|dlx)\s+|bunx\s+|yarn\s+)?hyperframes(?=\s|$)"), "hyperframes"),
    # headless chrome used as a renderer (screenshot / pdf / dom dump) — a bare launch is not matched
    (re.compile(r"chrom(?:e|ium)(?:-headless-shell)?\b[^|;&]*--headless[^|;&]*--(?:screenshot|print-to-pdf|dump-dom)|chrom(?:e|ium)(?:-headless-shell)?\b[^|;&]*--(?:screenshot|print-to-pdf|dump-dom)[^|;&]*--headless"), "headless chrome render"),
    # ffmpeg as a renderer: synthetic sources or a frame-sequence encode
    (re.compile(r"\bffmpeg\b[^|;&]*\s-f\s+lavfi\b"), "ffmpeg lavfi render"),
    (re.compile(r"\bffmpeg\b[^|;&]*\s-i\s+\S*%0?\d+d\.(?:png|jpe?g|webp)\b"), "ffmpeg frame-sequence encode"),
]


def check(cmd: str):
    """Return (label, matched_text) if cmd is a render, else None."""
    if not cmd:
        return None
    if re.search(r"(?:^|[\s;&|])FILAMENT_RENDER_ALLOWED=1\b", cmd):
        return None
    # Text is not execution. A heredoc body (writing a doc that MENTIONS a render) is never a
    # render, and neither is a quoted string handed to echo/grep/mesh-send. So: heredoc bodies are
    # dropped for every pattern, and quoted strings are dropped for the VERB patterns only — a
    # `node -e "require('@remotion/renderer')"` is code that executes inside its quotes, so the
    # toolchain-path pattern still sees the raw command. (A gate must not refuse the report of
    # its own refusal.)
    no_heredoc = re.sub(r"<<-?\s*['\"]?(\w+)['\"]?[^\n]*\n.*?\n\1(?:\n|$)", " ", cmd, flags=re.S)
    no_quotes = re.sub(r"'[^']*'|\"(?:[^\"\\\\]|\\\\.)*\"", "''", no_heredoc)
    for rx, label in PATTERNS:
        target = no_heredoc if label in ("remotion toolchain path",) else no_quotes
        m = rx.search(target)
        if m:
            return label, m.group(0)
    return None


def _self_test() -> int:
    cases = {
        "npx remotion render src/index.ts Main out.mp4": True,
        "pnpm exec remotion still src/index.ts Thumb out.png": True,
        "node -e \"require('@remotion/renderer')\"": True,
        "hyperframes render scene.html": True,
        "chromium --headless --screenshot=out.png https://example.com": True,
        "ffmpeg -f lavfi -i color=c=black:s=1280x720 -t 5 out.mp4": True,
        "ffmpeg -framerate 30 -i frame_%04d.png out.mp4": True,
        # must PASS
        "ls remotion-project": False,
        "mesh-send --to gpu-node@mesh --kind task --subject 'remotion render promo'": False,
        "ffmpeg -i in.wav -ar 16000 out.wav": False,
        "ls node_modules/.bin/hyperframes": False,
        "FILAMENT_RENDER_ALLOWED=1 npx remotion render src/index.ts Main out.mp4": False,
        "cat > notes.md <<'EOF'\nrun npx remotion render on the render node\nEOF\n": False,
    }
    bad = 0
    for cmd, want in cases.items():
        got = check(cmd) is not None
        ok = got == want
        bad += 0 if ok else 1
        print(f"{'ok  ' if ok else 'FAIL'} block={got!s:<5} want={want!s:<5} {cmd[:60]!r}")
    print(f"render-guard self-test: {len(cases) - bad}/{len(cases)} correct")
    return 1 if bad else 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        return _self_test()
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # not our shape — never block on a parse error
    cmd = ""
    ti = payload.get("tool_input") if isinstance(payload, dict) else None
    if isinstance(ti, dict):
        cmd = str(ti.get("command") or "")
    hit = check(cmd)
    if hit:
        label, text = hit
        sys.stderr.write(f"{_handoff()}\n  blocked: {label} — matched {text[:80]!r}\n")
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
