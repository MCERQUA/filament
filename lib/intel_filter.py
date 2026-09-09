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

FILTER_VERSION = "2026-08-16.1"

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
    # Z.AI / GLM key (SEC-048, 2026-08-25): <32 hex>.<16 alnum>, 49 chars. Added after a
    # LIVE ZAI_API_KEY was pasted plaintext into a mesh message and this filter PASSED it
    # (bun-desktop, third missed shape). No zai rule existed in ANY copy of this lib —
    # the shape was simply never covered, so the miss was structural, not a tuning error.
    # Anchored on the literal dot + exact segment lengths: a bare 32-hex md5 does not match,
    # and a filename like <md5>.tar.gz does not reach 16 alnum in one unbroken run.
    (r"\b[0-9a-f]{32}\.[0-9A-Za-z]{16}\b", "Z.AI / GLM API key (<32hex>.<16alnum>)"),
    (r"-----BEGIN [A-Z ]+-----",            "PEM / private key block"),
    (r"(?i)\bpassword\s*=\s*\S{4,}",        "password= assignment"),
    (r"(?i)\bauthorization\s*:\s*\S+",      "Authorization header value"),
    # ── SEC-038 criterion 3: vendor prefixes observed live on this fleet ──────
    # SHAPED, never bare: bare `mesh_` alone matched 206 legitimate passages in a
    # 6,205-file corpus — including this filter's own documentation. Shaped: 0 FPs.
    # Every rule is (?<![A-Za-z0-9_]) PREFIX CHARSET{LEN-4,} (?![A-Za-z0-9]).
    #   - LEN is the observed key length; the {LEN-4,} FLOOR (not {LEN} exact) because
    #     8 of 10 lengths rest on a single observed sample, and an exact quantifier
    #     silently under-blocks on any vendor length drift. Measured: floor == exact,
    #     same 4 hits at the same coordinates, 0 FPs over 6,208 files. The longest
    #     non-credential tail behind ANY of these prefixes in the corpus is 12 chars,
    #     so the tightest floor still has 20 chars of headroom.
    #   - BOTH lookarounds are load-bearing. The lookbehind kills prefix-mid-token
    #     (a hash that happens to contain `gsk_`); the trailing lookahead keeps the
    #     narrow-charset rules (hex, b64) from matching a hex-looking head of a
    #     wider alnum token.
    #   - npm_ is deliberately ABSENT (ASSIGN-only, no value-keyed counterexample) and
    #     pk_live_ is deliberately ABSENT (Clerk PUBLISHABLE key — ships in client
    #     bundles by design, so a rule for it is an FP generator by construction).
    (r"(?<![A-Za-z0-9_])am_us_[0-9a-f]{60,}(?![A-Za-z0-9])",        "AgentMail API key (am_us_...)"),
    (r"(?<![A-Za-z0-9_])ApiKey_[A-Za-z0-9._-]{76,}(?![A-Za-z0-9])", "InkBox API key (ApiKey_...)"),
    (r"(?<![A-Za-z0-9_])cfut_[A-Za-z0-9]{44,}(?![A-Za-z0-9])",      "Cloudflare API token (cfut_...)"),
    (r"(?<![A-Za-z0-9_])comfyui-[0-9a-f]{60,}(?![A-Za-z0-9])",      "ComfyUI Cloud API key (comfyui-...)"),
    (r"(?<![A-Za-z0-9_])fbk_sk_[A-Za-z0-9]{39,}(?![A-Za-z0-9])",    "FoamBook secret key (fbk_sk_...)"),
    (r"(?<![A-Za-z0-9_])gsk_[A-Za-z0-9]{48,}(?![A-Za-z0-9])",       "Groq API key (gsk_...)"),
    (r"(?<![A-Za-z0-9_])mesh_[0-9a-f]{44,}(?![A-Za-z0-9])",         "Mesh API key (mesh_...)"),
    (r"(?<![A-Za-z0-9_])msy_[A-Za-z0-9]{32,}(?![A-Za-z0-9])",       "Meshy API key (msy_...)"),
    (r"(?<![A-Za-z0-9_])nfp_[A-Za-z0-9]{32,}(?![A-Za-z0-9])",       "Netlify token (nfp_...)"),
    (r"(?<![A-Za-z0-9_])whsec_[A-Za-z0-9+/]{28,}(?![A-Za-z0-9])",   "webhook signing secret (whsec_...)"),
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


# ---------------------------------------------------------------------------
# CONDITIONAL RULES (SEC-032 shape coverage / SEC-038 groundwork).
# A plain (regex, desc) tuple cannot express "match, THEN exempt when the capture
# is obviously a placeholder" — these two need a predicate, so they live here.
#
# Landed 2026-08-14 from bun-desktop@mesh's canonical block VERBATIM, with
# security-officer@mesh's ship ruling. Measured before landing: 0 false positives
# across 6,809 (host) and 7,192 (bun) INDEPENDENT corpora; positive controls block;
# 9/9 URLCRED. The 16,211 figure that circulated earlier was a SUM of overlapping
# sets — the real union is 6,809.
#
# DO NOT reconstruct these from prose. The one recurring failure in this workstream
# was paraphrasing an artifact: a STOP-list paraphrase added `app`/`secret` and
# reopened a hole. Apply from the canonical block or not at all.
# ---------------------------------------------------------------------------

# Trimming this list re-enables the rule's self-censorship: documentation of a credential URL is
# written in these placeholder forms, and this exemption is the ONLY thing that stops the rule
# blocking its own ticket/reviews. Two properties are required and non-obvious:
#   (1) NO single letters — reintroduces the redis://u:p@ miss
#   (2) NO word plausible as a real short password (secret, app, test, dev, prod) — each re-opens a gap
# It shrinks under pressure, never grows.
URLCRED_STOP = {
    "admin", "bar", "changeme", "foo", "pass", "password", "pw", "service",
    "svc", "user", "username", "xxx", "your_password", "your_user", "yyy",
}

_ASSIGN_RE = re.compile(r"\b([A-Z][A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|KEY))\s*=\s*(\S{16,})")
_ASSIGN_REF_PREFIXES = ("os.", "self.", "process.", "$", "{", "<", '"', "'", "`", "...", "\u2026")
_ASSIGN_REF_SUBSTR = ("<", ">", "{", "}", "$", "*", "REDACTED", "...", "\u2026", "XXX",
                      "YOUR_", "environ", "getenv", "placeholder", "PASTE", "example")

_URLCRED_RE = re.compile(
    r"://([A-Za-z0-9._~%+-]{1,64}):([^@\s/\\\[\]{}()|^$*?]{1,128})@"
    r"([A-Za-z0-9.-]+\.[A-Za-z]{2,}|localhost|\d{1,3}(?:\.\d{1,3}){3})"
)


def _conditional_hits(line: str):
    """Rules that match then EXEMPT obvious placeholders. Returns [(snippet, desc)]."""
    out = []
    m = _ASSIGN_RE.search(line)
    if m:
        val = m.group(2)
        head = val[:60]
        if not (val.startswith(_ASSIGN_REF_PREFIXES)
                or any(t in head for t in _ASSIGN_REF_SUBSTR)):
            out.append((m.group(0)[:80], "credential ASSIGNMENT (NAME=<literal>)"))
    m = _URLCRED_RE.search(line)
    if m:
        # exempt ONLY when BOTH halves are placeholder words — one real half still blocks
        if not (m.group(1).lower() in URLCRED_STOP and m.group(2).lower() in URLCRED_STOP):
            out.append((m.group(0)[:80], "credential in URL (scheme://user:pass@host)"))
    return out


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
        else:
            # no builtin pattern matched this line — try the conditional rules
            for snippet, desc in _conditional_hits(line):
                hits.append((lineno, snippet, desc))
                break
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
        # Vendor-prefix fillers (SEC-038 c3). Motif slices, never real key material.
        _hex = "7f3a9c1e0b6d84f2" * 5      # 80 hex   [0-9a-f]
        _aln = "aB7xK2qR9zT4mW6" * 6       # 90 alnum [A-Za-z0-9]
        _b64 = "aB7+xK2/qR9z" * 4          # 48 std-b64 [A-Za-z0-9+/]
        _dot = "aB7.xK2-qR9_zT4" * 6       # 90 b64-ish [A-Za-z0-9._-]
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
            # ── ASSIGN + URLCRED coverage (SEC-038, 2026-08-15) ──────────────
            # The ASSIGN/URLCRED rules were LIVE but the self-test never exercised
            # them. bun-desktop's canonical fixture set (BLACKBOARD/sec-038/
            # intel-filter-selftest-negative-controls.md): "positives-green with
            # negatives-unrun is not a pass; it is an unmeasured rule." The
            # negatives are the only fixtures that separate a correct ASSIGN from
            # a blanket refuser. Values assembled from repeated chars so no literal
            # secret ships in source (same reason as the value-keyed cases above).
            # ASSIGN positives (NAME=<literal> must BLOCK; one in `export` form):
            "BRIDGE_TOKEN=" + "A" * 32: True,
            "export TWILIO_AUTH_TOKEN=" + "B" * 32: True,
            "CLIENT_SECRET=" + "C" * 32: True,
            "DB_PASSWORD=" + "D" * 32: True,
            "API_KEY=" + "E" * 32: True,
            # ASSIGN negatives (LOAD-BEARING — each tests a distinct pass path):
            "OVUI_GROUND_TAG_W=1024": False,                     # no keyword / value too short
            "the bridge token is rotated nightly": False,        # prose, no assignment
            "BRIDGE_TOKEN = os.environ.get('BRIDGE_TOKEN')": False,  # value is a reference (os.)
            "API_KEY=<your_api_key_placeholder_here>": False,    # placeholder (< + 'placeholder')
            # URLCRED positive (real-looking user:pass@host must BLOCK):
            "redis://appuser:" + "R" * 12 + "@10.0.0.5:6379": True,
            # URLCRED negatives (BOTH halves placeholder → exempt, must PASS):
            "postgresql://user:password@host.example.com": False,
            "redis://your_user:your_password@localhost": False,
            # ── SEC-038 criterion 3: vendor-prefix coverage (2026-08-15) ──────
            # Four cases per shipping prefix, and each one is load-bearing:
            #   OBSERVED  key at the length actually measured in env  -> must BLOCK
            #   FLOOR     key at exactly LEN-4, the quantifier floor  -> must BLOCK
            #   UNDER     key at LEN-5, one char below the floor      -> must PASS
            #   PROSE     a sentence naming the BARE prefix           -> must PASS
            # The UNDER cases are what prove the floor is a real boundary rather than
            # the rule matching everything; the PROSE cases are the entire reason these
            # rules are shaped, since bare `mesh_` matched 206 legitimate passages —
            # this filter's own docs among them. Keep BOTH halves or the pair measures
            # nothing. Fillers are motif slices, and the prefix is a SEPARATE literal
            # concatenated on, so no line of this source is itself key-shaped (same
            # constraint as the value-keyed cases above — the repo's secret gate reads
            # this file too, and it will read it with these very patterns loaded).
            # am_us_ — AgentMail, LEN 64 hex (N=3, fixed across samples)
            "am_" + "us_" + _hex[:64]: True,
            "am_" + "us_" + _hex[:60]: True,
            "am_" + "us_" + _hex[:59]: False,
            "the am_us_ prefix is AgentMail's, US region": False,
            # ApiKey_ — InkBox, LEN 80 (N=2, fixed across samples)
            "ApiKey" + "_" + _dot[:80]: True,
            "ApiKey" + "_" + _dot[:76]: True,
            "ApiKey" + "_" + _dot[:75]: False,
            "InkBox keys are shown with an ApiKey_ prefix in the dashboard": False,
            # cfut_ — Cloudflare, LEN 48 (N=1)
            "cfut" + "_" + _aln[:48]: True,
            "cfut" + "_" + _aln[:44]: True,
            "cfut" + "_" + _aln[:43]: False,
            "rotate the cfut_ token from the Cloudflare dashboard": False,
            # comfyui- — ComfyUI Cloud, LEN 64 hex (N=1)
            "comfyui" + "-" + _hex[:64]: True,
            "comfyui" + "-" + _hex[:60]: True,
            "comfyui" + "-" + _hex[:59]: False,
            "keys for that node are issued with a comfyui- prefix": False,
            # fbk_sk_ — FoamBook, LEN 43 (N=1)
            "fbk_sk" + "_" + _aln[:43]: True,
            "fbk_sk" + "_" + _aln[:39]: True,
            "fbk_sk" + "_" + _aln[:38]: False,
            "FoamBook mutations need the fbk_sk_ bearer, reads are open": False,
            # gsk_ — Groq, LEN 52 (N=1)
            "gsk" + "_" + _aln[:52]: True,
            "gsk" + "_" + _aln[:48]: True,
            "gsk" + "_" + _aln[:47]: False,
            "Groq keys start with gsk_ per their docs": False,
            # mesh_ — Mesh API, LEN 48 hex (N=1). 206 bare corpus hits, the worst offender.
            "mesh" + "_" + _hex[:48]: True,
            "mesh" + "_" + _hex[:44]: True,
            "mesh" + "_" + _hex[:43]: False,
            "the bare mesh_ prefix hit 206 legitimate lines, so the rule is shaped": False,
            # msy_ — Meshy, LEN 36 (N=1)
            "msy" + "_" + _aln[:36]: True,
            "msy" + "_" + _aln[:32]: True,
            "msy" + "_" + _aln[:31]: False,
            "Meshy 3D jobs authenticate with an msy_ key": False,
            # nfp_ — Netlify, LEN 36 (N=2, fixed across samples)
            "nfp" + "_" + _aln[:36]: True,
            "nfp" + "_" + _aln[:32]: True,
            "nfp" + "_" + _aln[:31]: False,
            "the nfp_ personal access token is set per deploy site": False,
            # whsec_ — webhook signing secret, LEN 32 std-b64 (N=1)
            "whsec" + "_" + _b64[:32]: True,
            "whsec" + "_" + _b64[:28]: True,
            "whsec" + "_" + _b64[:27]: False,
            "verify the callback against the whsec_ signing secret": False,
            # ── structural negatives (not per-prefix) ─────────────────────────
            # (a) prefix MID-TOKEN inside a longer run -> the LOOKBEHIND's whole job.
            #     Without (?<![A-Za-z0-9_]) this is a false positive on every hash that
            #     happens to contain a vendor prefix.
            "9f2ab7" + "gsk" + "_" + _aln[:52]: False,
            # (b) hash-like long token, no vendor prefix at all -> nothing should fire.
            #     The corpus holds 3,173 alnum runs >=20 chars and 206 hex runs; this
            #     stands in for all of them.
            "commit 9c1e0b6d84f27f3a9c1e0b6d84f27f3a9c1e0b6d": False,
            # (c) narrow-charset prefix whose tail is alnum but NOT hex -> the trailing
            #     LOOKAHEAD's whole job. With {LEN-4,} open-ended the lookahead is inert
            #     for the alnum rules (greedy eats the run), so hex/b64 is the ONLY place
            #     it still does work — which makes this the only case that measures it.
            "mesh" + "_" + _hex[:44] + "zq": False,
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
