# Contributing to Filament

Thanks for considering a contribution. Filament is small and likes to stay that way -- the framework is supposed to be readable end-to-end in an afternoon. Please keep that in mind when proposing changes.

## Filing issues

Open issues at <https://github.com/MCERQUA/filament/issues>. Useful issues include:

- A short description of what you tried.
- The exact command you ran and what you saw.
- Output of `mesh-on --check` (if relevant) and your `MESH_ROOT` layout (`tree -L 3 $MESH_ROOT/mesh`).
- Whether the bug reproduces in [`examples/two-agent-quickstart/`](examples/two-agent-quickstart/) -- if so, that's gold.

For protocol-level proposals (new message kinds, new directories, new fields), open an issue first so we can talk through the design before you write code. The protocol is the most important contract in the project.

## Pull requests

Small and focused. Each PR should do one thing.

- Reference the issue you're solving (or open one first if the change is non-trivial).
- Update relevant docs in the same PR (`docs/`, the script's own `--help`, `PROTOCOL.md` if you touched the wire format).
- If you added a new CLI in `bin/`, add a row to `scripts/canvas-generator/tasks.yaml` with a detection rule so it shows up on the dashboard.
- If you added a new operator script, ship a corresponding systemd `.service` + `.timer` pair.

## Agents contributing back

This is one of the more interesting use cases for Filament: agents that run *on* a Filament mesh can submit improvements *to* Filament via the same protocol. The pattern is:

1. Agent generates a `git format-patch` against its local clone of the framework.
2. Agent posts the patch to its `sent/` directory as a `KIND:patch` message addressed to `host@mesh`.
3. The host's `filament-patch-apply.timer` (every 5 min) picks it up, runs `git am --3way`, pushes to upstream, and acks the agent.

This is exactly what the `mesh-patch-apply.sh` script does. If you want to enable the same flow in your fork, point `FILAMENT_REPO` at your local checkout and the timer at your push remote.

We accept `KIND:patch` submissions from agents through the normal PR flow when they ship up to GitHub -- nothing is auto-merged into `MCERQUA/filament` from an external mesh.

## Code style

- **Shell:** POSIX-compatible where reasonable. `bash` is fine when you actually need bash features. Always `set -euo pipefail` (or document why not). Quote everything; `shellcheck` clean is a goal but not a hard rule.
- **Python:** stdlib-only for anything that ships in `bin/` or `scripts/`. Optional dependencies (PyYAML, etc.) must degrade gracefully.
- **YAML:** human-readable. Comments on non-obvious fields. No anchors / aliases unless they meaningfully reduce duplication.
- **No emojis** in code, docs, or commit messages.
- **No "Generated with Claude Code" / AI assistant footers.** If you used an AI tool, that's fine -- just don't tag the output.

## Testing

Filament doesn't ship a test framework. The minimum bar for a PR:

```bash
# Every modified shell script syntax-checks
for f in $(git diff --name-only main | grep -E '\.(sh)$'); do bash -n "$f" || exit 1; done

# Every modified Python script parses
for f in $(git diff --name-only main | grep -E '\.py$'); do python3 -c "import ast; ast.parse(open('$f').read())" || exit 1; done

# CLIs print --help without error
for f in bin/mesh-*; do "$f" --help >/dev/null 2>&1 || echo "FAIL: $f"; done
```

For changes that touch the protocol or message lifecycle, please run the two-agent quickstart end-to-end and confirm at least: send, recv, ack, BROADCAST publish, EVENTS subscribe.

## Security

If you find a security issue (especially in the AUTHOR validation path or the patch-apply flow), email mike@jam-bot.com instead of opening a public issue.

## License

By contributing you agree that your contributions are licensed under the MIT License (see [LICENSE](LICENSE)).
