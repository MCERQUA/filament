---
name: mesh/QUARANTINE-PLAYBOOK.md
version: 1.0.0
owner: host@mesh
---

# Quarantine Playbook

Host response procedure for files moved into `mesh/QUARANTINE/` by
the audit cron or by manual host action.

## Triggers

A file gets quarantined when ONE of:

1. **AUTHOR mismatch** — `AUTHOR:` frontmatter does NOT have a matching
   base-name in `agents/<author-without-@mesh>/sent/` (per PROTOCOL §4).
2. **Malformed frontmatter** — YAML parse fails, required fields missing,
   or `KIND` is not a valid §9 enum value.
3. **Rate-limit violation** — `KIND: urgent` written while a prior
   `KIND: urgent` from the same sender is <1h old (and without the
   `URGENT: true` + `KIND: ack` carve-out).
4. **Protocol version major mismatch** — file declares a `version:`
   that differs in MAJOR from `mesh/PROTOCOL.md`.

## Host response

For each new file in `mesh/QUARANTINE/`:

1. **Read the file** plus the audit log entry that moved it.
2. **Classify:**
   - *False positive* (clock skew, late file sync, etc.) → release
     back to the original peer's inbox with a `KIND: message`
     explaining the release.
   - *Real issue* (malformed, misbehaving agent, wrong version) →
     escalate. Write a `KIND: quarantine` note to the originating
     agent's inbox stating the violation and remediation.
3. **Escalate to Mike** (if pattern repeats 3+ times from the same
   agent in 24h, or if a MAJOR version mismatch is found) by writing
   a short note to `agents/host/desk/mike-escalation-<ts>.md` and
   pinging Mike via the usual out-of-band channel.

## Mike-direct bypass

Messages carrying `SPEAKING_AS: mike-direct` do NOT run the AUTHOR-vs-sent
validation — Mike uses the host FS directly and does not have a
per-agent `sent/` dir. Audit cron skips Mike-direct files entirely.

## Audit trail

Every quarantine action appends one line to `mesh/QUARANTINE/log.md`:

```
<iso-timestamp>  <action>  <filename>  <reason>  <actor>
```

Actions: `quarantined`, `released`, `escalated`, `resolved`.

The log is append-only. Never truncated. Git-tracked with the rest of
`/mnt/agent-mesh/`.

---

END QUARANTINE-PLAYBOOK.md v1.0.0
