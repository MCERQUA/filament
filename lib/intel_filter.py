"""PROTOCOL §19 pre-send intel filter — THE single implementation.

SEC-032. Every mesh CLI that writes agent-authored text into fleet-readable shared
space (/mnt/agent-mesh is root-mounted into 32 containers as uid 1000 with zero
isolation) MUST run this filter before writing.

Do NOT copy these patterns into a tool. Import this module. Per-tool copies rot:
on 2026-08-03 the host's own live mesh-send was still running the 2026-04-25
pattern set and passed 9 of 12 secret classes that the 2026-07-28 set blocks —
including Anthropic `sk-ant-*` and OpenAI `sk-proj-*` keys.

Import contract for callers (fail-closed — see `loader_snippet()` below):
    _IF = _load_intel_filter()          # exits 4 if this module cannot be found
    _IF.enforce(body, agent_dir, force=args.force_leak, tool="mesh-event")

FILTER_VERSION is the drift handle. Bump it whenever the pattern set changes;
`mesh-filter-verify` compares the version reported by every tool on every node.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

FILTER_VERSION = "2026-08-03.1"

# ---------------------------------------------------------------------------
# Built-in secret / PII patterns.
#
# Every entry below carries the reasoning that produced its exact shape. These
# are field-tuned against real false positives and real misses — read the note
# before you "tighten" or "broaden" one.
# ---------------------------------------------------------------------------
BUILTIN_FILTER_PATTERNS: list[tuple[str, str]] = [
    (r"\bhf_[A-Za-z0-9]{20,}\b",            "HuggingFace token (hf_...)"),
    (r"\bAIza[A-Za-z0-9_-]{30,}\b",         "Google API key (AIza...)"),
    # Google OAuth REFRESH token (1//...). Lookbehind excludes base64-only chars
    # [A-Za-z0-9+/] before — kills embedded-base64 FPs (bun's 1.7MB img blob) — but NOT
    # '=', because refresh_token=1//... is the #1 real context and must still block.
    # {50,} floor: real tokens are 100+ chars; short 1// (URL /v1//, paths) passes.
    (r"(?<![A-Za-z0-9+/])1//[A-Za-z0-9_-]{50,}", "Google OAuth refresh token (1//...)"),
    # sk- SHAPED, not broad (host decision 2026-07-28, src/bun cost data): a real key
    # always ends in an unbroken 20+ alnum run; prose/branch slugs are hyphen-separated
    # short words and pass. Catches sk-proj-* / sk-ant-* (the old pattern MISSED both —
    # the hyphen after proj/ant broke the run, so real modern keys sailed through while
    # src's broad per-desk rule was blocking branch names). Broad-class rejected: a
    # filter that cries wolf gets --force-leak'd into decay.
    (r"\bsk-(?:[A-Za-z0-9]+-)*[A-Za-z0-9_]{20,}\b", "API key (sk-...)"),
    (r"\bsk_(?:live|test)_[A-Za-z0-9]{16,}\b",      "Stripe secret key (sk_live_/sk_test_)"),
    (r"\bxox[baprs]-\d{8,}-[A-Za-z0-9-]{10,}\b",    "Slack token (xox..-<digits>-...)"),
    (r"eyJ[A-Za-z0-9+/=]{30,}",             "JWT token (eyJ...)"),
    (r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",      "AWS access key (AKIA/ASIA...)"),
    # {30,} floor, NOT {36} exact: trailing \b makes an exact-length pattern silently
    # PASS any longer token (bun/src proved it live). ghr_ included — refresh tokens
    # have the longest leak tail: they mint new access tokens until revoked.
    (r"\bgh[opsur]_[A-Za-z0-9]{30,}\b",      "GitHub token (ghp/gho/ghs/ghu/ghr_...)"),
    (r"\bgithub_pat_[A-Za-z0-9_]{59,}\b",   "GitHub fine-grained token"),
    (r"\baia_sk_[A-Za-z0-9]{20,}\b",        "AIA secret key (aia_sk_...)"),
    (r"-----BEGIN [A-Z ]+-----",            "PEM / private key block"),
    (r"(?i)\bpassword\s*=\s*\S{4,}",        "password= assignment"),
    (r"(?i)\bauthorization\s*:\s*\S+",      "Authorization header value"),
]


def load_private_context(agent_dir) -> list[tuple[str, str]]:
    """Load per-agent filter patterns from <agent_dir>/private_context.md.

    Format — one entry per line, prefix determines category:
        client: <regex>   client name / PII (company, employees, contacts)
        domain: <regex>   domain / hostname patterns
        secret: <regex>   custom secret formats (API keys, internal tokens)
    Blank lines and lines starting with # are ignored.
    """
    if agent_dir is None:
        return []
    ctx = Path(agent_dir) / "private_context.md"
    if not ctx.is_file():
        return []
    patterns: list[tuple[str, str]] = []
    labels = {"client": "client pattern", "domain": "domain pattern", "secret": "custom secret"}
    try:
        with ctx.open("r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                for prefix, label in labels.items():
                    key = f"{prefix}: "
                    if line.startswith(key):
                        pat = line[len(key):]
                        patterns.append((pat, f"{label}: {pat[:50]}"))
                        break
    except OSError:
        pass
    return patterns


def run(body: str, agent_dir=None) -> list[tuple[int, str, str]]:
    """Scan body lines for secrets / PII. Returns [(line_no, snippet, description)]."""
    all_patterns = BUILTIN_FILTER_PATTERNS + load_private_context(agent_dir)
    hits: list[tuple[int, str, str]] = []
    for lineno, line in enumerate(body.splitlines(), 1):
        for pat, desc in all_patterns:
            try:
                m = re.search(pat, line)
            except re.error:
                continue
            if m:
                start = max(0, m.start() - 15)
                snippet = line[start:m.end() + 15].strip()
                hits.append((lineno, snippet, desc))
                break  # one hit per line is enough
    return hits


def format_hits(hits, tool: str, dest: str = "", force_flag: str = "--force-leak") -> str:
    lines = [
        "",
        f"  BLOCKED by PROTOCOL §19 intel filter ({tool}, filter {FILTER_VERSION})",
        "",
        f"  {len(hits)} line(s) matched a secret / PII pattern.",
    ]
    if dest:
        lines.append(f"  Destination: {dest}")
    lines.append("")
    for lineno, snippet, desc in hits[:20]:
        lines.append(f"    line {lineno}: {desc}")
        lines.append(f"      ...{snippet}...")
    if len(hits) > 20:
        lines.append(f"    ... and {len(hits) - 20} more")
    lines += [
        "",
        "  /mnt/agent-mesh is readable by every agent on the fleet. Anything written",
        "  here is plaintext to 32 containers and redaction requires a commit.",
        "",
        f"  Send a POINTER to the secret's location, not the secret. If this is a",
        f"  false positive, re-run with {force_flag} (audited to mesh/DECISIONS/).",
        "",
    ]
    return "\n".join(lines)


def enforce(body: str, agent_dir=None, force: bool = False, tool: str = "mesh-tool",
            dest: str = "", force_flag: str = "--force-leak", exit_code: int = 4):
    """Run the filter and EXIT if it trips. Returns hits (possibly non-empty when forced).

    This is the one call a tool needs. It fails closed: any unexpected error inside
    the filter aborts the write rather than passing the body through.
    """
    try:
        hits = run(body, agent_dir)
    except Exception as exc:  # noqa: BLE001 - fail closed, never pass-through on error
        sys.stderr.write(
            f"\n  FATAL: PROTOCOL §19 intel filter errored in {tool}: {exc!r}\n"
            f"  Refusing to write to shared mesh space (fail-closed).\n\n"
        )
        raise SystemExit(exit_code)
    if hits and not force:
        sys.stderr.write(format_hits(hits, tool, dest, force_flag) + "\n")
        raise SystemExit(exit_code)
    return hits


# ---------------------------------------------------------------------------
# Loader — copy this into each tool verbatim. It is the ONLY thing that gets
# duplicated, and it contains no patterns, so it cannot drift in a way that
# weakens the filter: if it fails to find this module the tool exits non-zero.
# ---------------------------------------------------------------------------
LOADER_SNIPPET = '''
def _load_intel_filter():
    """Import the shared PROTOCOL §19 filter. Fail CLOSED if unavailable."""
    import importlib.util, os, sys
    from pathlib import Path
    cands = []
    env = os.environ.get("MESH_INTEL_FILTER")
    if env:
        cands.append(Path(env))
    here = Path(__file__).resolve().parent
    cands.append(here.parent / "lib" / "intel_filter.py")
    for p in ("/mnt/system/base/skills/agent-mesh/lib",
              "/mnt/shared-skills/agent-mesh/lib",
              "/skills/agent-mesh/lib",
              "/home/mike/filament/lib",
              str(Path.home() / ".local/lib/agent-mesh")):
        cands.append(Path(p) / "intel_filter.py")
    for c in cands:
        try:
            if c.is_file():
                spec = importlib.util.spec_from_file_location("mesh_intel_filter", c)
                mod = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(mod)
                return mod
        except Exception:
            continue
    sys.stderr.write(
        "\\n  FATAL: PROTOCOL \\u00a719 intel filter lib (intel_filter.py) not found.\\n"
        "  Refusing to write to shared mesh space without a secret filter (SEC-032, fail-closed).\\n"
        "  Searched: " + ", ".join(str(c) for c in cands) + "\\n\\n")
    sys.exit(4)
'''


def loader_snippet() -> str:
    return LOADER_SNIPPET


if __name__ == "__main__":
    # `python3 intel_filter.py --version` → drift handle for mesh-filter-verify
    if len(sys.argv) > 1 and sys.argv[1] == "--version":
        print(FILTER_VERSION)
    elif len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        # Fixtures are ASSEMBLED FROM PARTS on purpose: a literal key-shaped string
        # here would trip the repo's own pre-commit secret gate (it did — the gate
        # blocked this file for containing a fake xoxb token and a PEM header).
        # A secret detector must not ship source that looks like a secret. Never
        # SECRETS_ALLOW=1 past that; reshape the fixture.
        _b = "b-12345678901-"
        cases = {
            "sk-" + "ant-api03-" + "A" * 40: True,
            "sk-" + "proj-" + "B" * 45: True,
            "gh" + "p_" + "D" * 40: True,
            "gh" + "r_" + "E" * 36: True,
            "AS" + "IA" + "F" * 16: True,
            "AI" + "za" + "G" * 33: True,
            "refresh_token=" + "1//" + "H" * 60: True,
            "sk_" + "live_" + "I" * 24: True,
            "xox" + _b + "J" * 20: True,
            "hf" + "_" + "K" * 30: True,
            "-----BEGIN " + "RSA PRIVATE KEY" + "-----": True,
            "the sk- prefix is used by openai": False,
            "branch feat/sk-rewrite-cache": False,
            "see https://example.com/v1//path": False,
        }
        bad = 0
        for text, should_block in cases.items():
            got = bool(run(text))
            ok = got == should_block
            if not ok:
                bad += 1
            print(f"{'ok  ' if ok else 'FAIL'}  block={got!s:<5} want={should_block!s:<5}  {text[:52]}")
        print(f"\nfilter {FILTER_VERSION}: {len(cases) - bad}/{len(cases)} cases correct")
        sys.exit(1 if bad else 0)
    else:
        print(f"intel_filter {FILTER_VERSION} — {len(BUILTIN_FILTER_PATTERNS)} builtin patterns")
