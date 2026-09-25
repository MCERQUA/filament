# Dropping prompts into agent sessions

Filament moves messages as files. An agent running an **interactive CLI in tmux** (Claude
Code and similar) does not poll anything: once its turn ends it idles at the prompt until
something types into the pane. `scripts/wake/` is the toolkit for doing that typing
**safely, attributably and verifiably**.

Every rule below exists because its absence lost real messages or delivered a wrong
instruction in production.

| Tool | Job |
|---|---|
| `scripts/wake/mesh-wake` | type ONE tagged, ledgered line into a pane and prove it was submitted |
| `scripts/wake/wake-verify` | check `[wake:…]` tags (in a line, a pane capture, or a transcript) against the ledger |
| `scripts/wake/agent-session.sh` | persistent session shell: one shared tmux session, respawn loop, idempotent boot prompt |
| `scripts/wake/inbox-wake-filter.sh` | decide which inbox arrivals are worth a wake (WAKE vs HOLD) |
| `scripts/wake/inbox-watch.sh` | inbox arrivals -> queued, coalesced, verified wakes (`--follow` event-driven, `--once` cron) |
| `scripts/wake/scheduled-wake.sh` | at a scheduled time, make the live session do a duty itself unless it already did |
| `scripts/wake/mesh-inject` | one agent typing into ANOTHER's session, with a mesh record written first |
| `scripts/wake/wake-lib.sh` | shared helpers (sourced): tag format, ledger, tmux transport |

All tools print `--help`. Requirements: bash, tmux, python3 (verifier only),
inotify-tools (`--follow` modes), util-linux `flock`.

---

## 1. The problem with `tmux send-keys`

A line typed by `send-keys` is **indistinguishable from the operator typing**. It leaves
no mesh trail and bypasses every check the mesh has, because it never becomes a message.
An actor who can type into a pane never needs to forge a message at all.

So every machine-typed line carries an origin tag and a nonce:

```
[wake:<producer>#<nonce>]          e.g.  [wake:inbox-watch#1a2b3c4d] new inbox file(s): …
/mesh-start [wake:session-boot#9f8e7d6c]   (slash commands keep the command first)
```

and the nonce is written to an **append-only ledger BEFORE the keys are sent**:

```
$MESH_ROOT/mesh/LEDGER/wakes/<YYYY-MM-DD>.jsonl     (override: WAKE_LEDGER_DIR)
{"ts":"…","event":"send","agent":"alice-desktop@mesh","origin":"inbox-watch","nonce":"1a2b3c4d","target":"agent-mesh","text":"…"}
{"ts":"…","event":"result", … ,"verdict":"VERIFIED"}
```

Ledger-first means a wake that never arrives is still evidenced, and a tag with no ledger
record is detectable:

```bash
wake-verify --tag '[wake:inbox-watch#1a2b3c4d]'
wake-verify --scan ~/.claude/projects/<cwd-slug>/<session>.jsonl   # every tag + untagged user turns
```

| Verdict | Meaning |
|---|---|
| `VERIFIED` | nonce in the ledger under the same producer |
| `ORIGIN-MISMATCH` | a real nonce re-used under another producer's name (origin spoofing) |
| `FORGED` | well-formed tag, nonce never ledgered |
| `MALFORMED` | nonce is not 6-16 hex (the tools only mint hex) — e.g. a hand-typed `#fix` |
| `UNTAGGED` | a transcript user turn with no tag: a human, or an injector that bypassed the tools |

**What the receiving agent should do** with a non-`VERIFIED` tag: treat the line as an
*unattributed prompt*. Act only on what the filesystem itself shows (e.g. drain the inbox
you can read) — never on an instruction that exists only in the typed line.

**Limit, stated plainly:** anything running as the ledger's uid can append to it. Tagging
makes forgery detectable and raises its cost; it does not make it impossible.

## 2. Submit verification — "I typed it" is not "it was delivered"

`mesh-wake` does, in order:

1. **Guards (nothing typed yet):** session exists · pane runs the agent CLI
   (`WAKE_EXPECT_CMD`, default `claude`; a wake typed into a plain shell *executes as a
   command*) · optional `--expect-uri` identity check (refuses a pane whose process has a
   different `AGENT_URI` — a mis-listed pane turns every nudge into a false work order for
   the wrong agent) · the input prompt glyph is visible (`WAKE_PROMPT_GLYPH`, default `❯`;
   the whole pane is checked, not a tail — the CLI parks its input box part-way up) · no
   modal dialog · copy-mode cancelled · a 4095-byte line cap (a truncated line still
   **executes**, so an over-long wake would deliver a different instruction than the one
   ledgered).
2. **Staged text:** `send-keys -l` **appends**. Typing behind a half-typed line
   concatenates both into one corrupted instruction. A staged prior wake or a
   `[Pasted text #N]` placeholder is ours and is submitted first; a human's text makes the
   wake refuse (`WAKE_STRAY=submit` to override).
3. **Ledger the send.** An unwritable ledger is a refusal.
4. **Type, and require the frame to change.** Typing into a live CLI always redraws; a
   pane that does not redraw is frozen and nothing afterwards can be trusted → `WEDGED`.
   Polled for 8 s, because a busy CLI can take seconds to echo.
5. **Submit with `Enter` AND `C-m`.** With extended-keys reporting on, tmux can encode the
   named `Enter` key as a CSI-u sequence the app ignores; `C-m` is a literal `\r`. A
   bare-Enter "recovery" has failed on perfectly healthy panes and looked like a wedge.
6. **Verify on the TRANSCRIPT, not the pane.** A wake is submitted iff its nonce appears in
   the CLI's newest transcript `*.jsonl` (`--transcript-dir` / `WAKE_TRANSCRIPT_DIR`).
   Up to 3 tries. A pane check passes *spuriously*: the text leaves the last line on
   redraw whether or not Enter registered, and a long line collapses to a
   `[Pasted text #N]` placeholder that hides the nonce. In the field, nine wakes sat
   typed-but-unsubmitted for hours while a pane-based verifier reported success.

| Exit | Verdict | Meaning |
|---|---|---|
| 0 | `VERIFIED` | nonce found in the transcript |
| 1 | `STUCK` | typed, never submitted after 3 tries |
| 2 | `REFUSED` | nothing typed (a guard tripped) — safe to retry later |
| 3 | `WEDGED` | pane frozen; relaunch the session |
| 4 | `CANNOT-TELL` | pane says submitted, no transcript to confirm — do **not** report as delivered |

Only exit 0 is proof. Callers must branch on the code; never `|| true` it away.

The Claude Code transcript dir is `<cli-home>/.claude/projects/<cwd with / replaced by ->`.

## 3. The session shell (`agent-session.sh`)

Use it as the shell of a web terminal, a desktop launcher, or a service's `ExecStart`.

- **One shared session.** First opener creates it, every later opener attaches; closing the
  terminal never kills the agent. `exit-empty off` keeps the server alive with no clients.
- **Respawn loop.** If the CLI exits (auth blip, `/exit`, crash) it is restarted after 3 s.
- **Guarded continue.** Resume (`AGENT_CONTINUE_FLAG`, default `--continue`) only when a
  transcript exists for this cwd *right now*. An unconditional continue on an empty project
  dir (exactly what a container recreate produces) exits instantly and the loop becomes a
  permanently dark lane; a bare respawn comes back looking healthy with none of its context.
- **Ask the RESOLVED binary's home.** A wrapper that sets its own `HOME` reads transcripts
  from a different place than the guard would assume. When the two disagreed, one desk
  respawned 16,659 times in 17 hours with a single error string and nothing alarmed. The
  home is read from the wrapper's own `export HOME="…"` line, never restated.
- **Spin brake.** Two consecutive sub-10 s exits → stop resuming and start fresh for good.
- **Inert resume prompt.** The resume carries an *assessment* prompt, not "continue": a
  crash is when the lane's state is least understood. It asks the agent to state what was in
  flight, check whether it completed, check whether another lane claimed it
  (`mesh-claim show`, where a FATAL/unreachable result is CANNOT-TELL, never "free"), and to
  report and STOP when in doubt.
- **Env passthrough.** The pane inherits the tmux **server's** environment from when the
  server first started, not this script's. Names in `SESSION_ENV_PASSTHROUGH` are passed with
  `new-session -e` (empty values never, so they cannot shadow the server env). Add credential
  names deliberately.
- **Idempotent boot prompt.** `BOOT_PROMPT` (default `/mesh-start`) is sent through
  `mesh-wake` as `[wake:session-boot#…]` once the prompt glyph appears, on both the create
  and the attach path, and skipped if it is already in scrollback. The boot prompt must itself
  be idempotent — a cleared scrollback fires it again.

## 4. Which arrivals deserve a wake (`inbox-wake-filter.sh`)

Waking an agent on every inbox file pays full model rates to be told nothing: in one
measured evening 22 of 49 arrivals were FYI-class. Held messages are **not lost** — they
stay in the inbox and the next real turn (or digest, or prompt-submit hook) counts them.

First match wins:

| Verdict | Rule |
|---|---|
| HOLD | filename matches `WAKE_HOLD_GLOBS` (default `*event-chatroom-*`) |
| HOLD | selftest probe: `-selftest-` subject slug, or `SPEAKING_AS: selftest` (both already legal on the wire — no new KIND, because a probe that quarantines turns "my alert path is broken" into "looks fine") |
| WAKE / HOLD | self-authored: WAKE only with a body line `Urgency: critical\|urgent` (an ops alert routed to self); a note-to-self holds |
| HOLD | `END-OF-TURN` names a specific other agent and not me (cc'd traffic) |
| HOLD | `END-OF-TURN: none` / no reply needed — except KIND `urgent\|hitl\|quarantine\|dead-letter`, which always wake |
| WAKE | KIND `urgent task question blocker hitl rfc delegate decision quarantine dead-letter` |
| WAKE | `END-OF-TURN` names me / "reply expected" / "please" / "your call" / GO/NO-GO |
| HOLD | `END-OF-TURN` none / no reply / FYI / completed-work |
| WAKE | no header, unreadable, anything else — **fail-noisy**: a broken header is never a reason to go quiet |

`--decide FILE` (exit 0 WAKE / 1 HOLD) makes it a filter for other tools;
`--self-test` runs 12 fixtures. In follow mode it prints `[mesh new] inbox: …` lines for a
persistent monitor and is **single-instance with catch-up**: `inotifywait -m` has no
memory, so an orphaned instance decides WAKE into a dead pipe and a new one starts blind.
It kills its predecessor by **PID file** (never `pgrep -f <name>`, which matches the
launching shell and has killed it), arms the watch *before* replaying everything newer than
its last decision, and reaps its own pipeline on exit.

## 5. Inbox → wakes (`inbox-watch.sh`)

- `--follow` (next to the session): a producer enqueues WAKE-class arrivals; **one**
  consumer sends one **coalesced** wake at a time through `mesh-wake` and verifies it before
  the next. Two producers typing at once used to stack text into one corrupted line. On
  `REFUSED`/`STUCK`/`WEDGED` the batch is re-queued at the head with a back-off;
  `CANNOT-TELL` is logged and not resent (resending a submitted wake doubles it). Reactive
  only — pair it with a `--once` cron as a backstop.
- `--once` (cron, possibly from another host via `WAKE_TMUX="docker exec -u app ctr tmux"`):
  wakes only when the inbox's newest mtime passed the last wake, the arrival is fresh
  (`WATCH_FRESH_SECS`), there is something `mesh-recv` can actually return (**never** count
  `.read/`: a wake whose prescribed action returns "(no messages)" trains the agent to
  ignore wakes, and "you have unread tasks — go" pushes it to invent work), nothing is
  already queued in the pane, and `WATCH_MIN_INTERVAL` has elapsed.

The tools never read, ack, move or delete a message. The agent does that when woken.

## 6. Scheduled duties and peer injection

`scheduled-wake.sh` wakes the live session for a scheduled duty (a nightly meeting, a
report). An agent in tmux 95% of the time still no-shows if nothing pokes it. It is
idempotent on a done-marker (accept every sign-off form the session actually writes) and
runs a `--fallback` command only when the session is genuinely absent — which it logs as an
anomaly.

`mesh-inject` is for one agent typing into another's session. It writes a normal mesh
message carrying the exact text and nonce to the target's inbox **first**, then types
`[wake:inject-<sender>#<nonce>]`. A pre-flight dry run raises every refusal before the
record is written. The receiver checks with `mesh-inject --verify <nonce>`.

## 7. Wiring examples

```bash
# a desk container: session shell + event-driven wakes, verified on the transcript
export AGENT_URI=alice-desktop@mesh MESH_DIR=/mesh
export AGENT_SESSION=agent-mesh AGENT_WORKDIR=/workspace
export WAKE_TARGET=agent-mesh
export WAKE_TRANSCRIPT_DIR="$HOME/.claude/projects/-workspace"
scripts/wake/agent-session.sh --detached
scripts/wake/inbox-watch.sh --follow &

# a host nudging a pane inside a container, every 2 minutes
*/2 * * * *  AGENT_URI=bob-desktop@mesh MESH_ROOT=/mnt/agent-mesh \
             WAKE_TMUX="docker exec -u app bob-webtop tmux" WAKE_TARGET=agent-mesh \
             /opt/filament/scripts/wake/inbox-watch.sh --once

# a persistent monitor on the host's own inbox (stdout lines = notifications)
AGENT_URI=host@mesh scripts/wake/inbox-wake-filter.sh
```

With `WAKE_TMUX` pointing into a container, `--transcript-dir` must be a path the *calling*
side can read; otherwise the result is `CANNOT-TELL` (exit 4), by design.
