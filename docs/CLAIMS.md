# Claims — `mesh-claim`

**Never start work that something else may already be doing.** Take an exclusive claim
first, and refuse to start if a live claim exists.

`bin/mesh-claim` is the tool. It exists because "grep the ledger for a prior claim" is not a
guard when nothing writes a claim: *being worked interactively leaves no trace a dispatcher
can see*, so two lanes (a dispatcher and a human-driven session, or two relays sharing one
inbox) end up doing the same task — two restarts of the same live service, a finished
deliverable rebuilt from scratch by a duplicate.

## What a real claim needs — all four

| requirement | how `mesh-claim` satisfies it |
|---|---|
| written BEFORE the work starts (a receipt is not a claim) | you run `take` first and act only on exit 0 |
| ATOMIC (check-then-write races) | `mkdir(2)` of `<key>.claim` |
| an OWNER (so a human can find them) | `AGENT_URI` + host recorded; an unset `AGENT_URI` is **refused**, never defaulted |
| an EXPIRY (a dead holder must not wedge the key) | TTL; expired claims are reaped |

Interactive work claims too. A session picking a task up by hand takes the same claim, or it
stays invisible to every dispatcher.

## Verbs

```
mesh-claim take    <key> [ttl]          # ttl = seconds or <n>[smhd]; default $MESH_CLAIM_TTL or 1800
mesh-claim extend  <key> <ttl> [born]   # lengthen a LIVE claim you hold; born is never rewritten
mesh-claim release <key>                # owner only
mesh-claim done    <key> [note]         # record completion (first completion is immutable) + release
mesh-claim show    <key>                # 0 LIVE · 1 free · 2 EXPIRED · 70 cannot tell
mesh-claim reap    all                  # sweep every past-TTL claim
```

Keys are arbitrary strings (`inbox:<message-filename>`, `deploy:<site>`, a task slug).

## Exit codes — ONLY EXIT 2 MEANS HELD

| rc | meaning | caller should |
|---|---|---|
| 0 | you hold it | proceed |
| **2** | **HELD by another lane** | **stand down** — the only code that means this |
| 3 | refused: `AGENT_URI` unset, or not the owner | fix the environment; do NOT stand down silently |
| 64 | usage / bad TTL | fix the call |
| 70 | claims root missing or unwritable — **the lock provides no exclusion at all** | fail loudly |
| 75 | cannot tell: unreadable born/ttl on an existing claim | fail loudly |

### NEVER write `mesh-claim take "$KEY" || exit 0`

That one-liner stands down on 3, 64, 70 and 75 exactly as it does on 2 — silently, with a log
indistinguishable from a healthy lock doing its job. Measured in production: an operator pasted
a claim line from an alert into a shell without `AGENT_URI`, got exit 3, and the `|| exit 0`
wrapper printed "HELD — stand down". Nothing was held. A false positive that renders as success
is unauditable.

The correct caller — quiet on held, loud on broken:

```bash
KEY="inbox:$MSG"
mesh-claim take "$KEY" 1800; rc=$?
case $rc in 0) ;; 2) exit 0 ;; *) echo "mesh-claim rc=$rc is NOT 'held'" >&2; exit $rc ;; esac
# ...work...
mesh-claim done "$KEY" "what was done"      # or: mesh-claim release "$KEY"
```

## Dispatching to a child: the child is not a second taker

A dispatcher that takes the claim and spawns a session to do the work will have that child
follow the rule above, be told HELD **by its own parent**, and abort — the dispatched work
silently never happens, and it logs exactly like the lock working. Both carry the same
`AGENT_URI`; only the process tree knows. Pass the exact key down:

```bash
mesh-claim take "$KEY" 1800; rc=$?; case $rc in 0) ;; 2) exit 0 ;; *) exit $rc ;; esac
MESH_CLAIM_INHERITED="$KEY" my-agent-cli ...     # child's own take() returns 0 (INHERITED=1)
mesh-claim release "$KEY"                        # the PARENT releases, once
```

The variable must name the EXACT key and the recorded owner must still match, so it is not a
blanket bypass — a rival URI or a wrong key still gets HELD.

### Over ssh the marker silently does not arrive

`ssh` forwards no environment. Put the marker on the REMOTE command line:

```bash
MESH_CLAIM_INHERITED="$KEY" ssh node '...'      # ✗ dies locally, never crosses
ssh node "MESH_CLAIM_INHERITED='$KEY' ..."      # ✓ set inside the remote command
```

A test harness that composes its *own* ssh command (with the marker) stays green while the
production caller (without it) gets HELD on every run. The only test of a join is the
production function, unstubbed, against the real peer. And a fallback that *labels its cause*
("peer is too old") is asserting something it did not measure — make it print the two commands
that would discriminate instead.

## Long work: extend, don't guess

A TTL that lapses under running work turns a working lock into a collision: the claim expires,
`take` reaps it as stale, and a second lane starts the same task mid-way. Size the claim to the
work with `extend`. Record the `born` value you were granted and pass it to `extend`; a mismatch
means your claim lapsed and was re-taken by someone else, and you get exit 2.

## Where claims live

Resolution order: `MESH_CLAIM_ROOT` (alias `MESH_CLAIMS_DIR`) → `$MESH_ROOT/mesh/CLAIMS` →
`/mnt/agent-mesh/mesh/CLAIMS` (host) → `/mesh/CLAIMS` (container). The parent directory must
already exist: the tool never `mkdir -p`s its way to a private directory, because a
container-local claims dir would let `take` succeed while being invisible to every other agent —
a lock that reports mutual exclusion and provides none.

Layout: `<key>.claim/{owner,born,ttl,where,renewals}` and `<key>.done/{owner,at,note,history}`.
The `where` file records the helper's pid, which is **always dead** — liveness is the TTL only.
