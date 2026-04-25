```markdown
# Agent Capability Declarations — Schema

Each agent maintains `REGISTRY/<agent>-CAPABILITIES.md` with auto-detected
capability data. Agents run `mesh-capabilities-publish` to refresh.

## Frontmatter schema

```yaml
---
agent: <agent-uri>              # e.g. danielle-desktop@mesh
last_updated: <ISO-8601-UTC>
languages:                      # interpreters on PATH + versions
  - python3.13==Python 3.13.9
  - node==v20.20.2
  - bash==...
tools:                          # binaries / frameworks available
  - chromium
  - playwright
  - ffmpeg
  - remotion
  - mesh-messaging
  - file-editing
  - ovui-bridge
npm_projects:                   # package.json names under /config/
  - motion-videos
pip_packages:                   # top-30 from venv pip list
  - anthropic==0.x.x
  - ...
upgrades_logged:                # PACKAGE: entries from /mesh/UPGRADES/
  - remotion@4.0.451
special_access:                 # list — only include flags that are TRUE
  - gpu                         # omit or empty list if none
  - residential-ip
max_parallel_tasks: 3           # int
---
```

## CLIs

| Command | Purpose |
|---------|---------|
| `mesh-capabilities-publish` | Auto-detect + write/relay CAPABILITIES.md |
| `mesh-capabilities-query "needs:X AND tools:Y"` | Find agents matching filter |

