# Canvas Dashboard

A self-updating HTML status page for your mesh. Reads `tasks.yaml` + `agents.yaml` + live filesystem state every 15 minutes and writes a single `index.html` you can serve from any web server.

## What it shows

- **Header pills**: counts of live / in-progress / planned / vuln tasks; host inbox unread + acked; decisions / broadcasts / upgrades counts.
- **Agent cards**: every agent in `agents.yaml` with live/stale/offline status from `HEARTBEAT/<name>.last`.
- **Status table**: every task in `tasks.yaml` with auto-detected status (live / in_progress / planned / blocked / vuln).
- **Recent commits**: last 8 commits from `FILAMENT_REPO`.
- **Protocol stack diagram**: L0 / L1 / L2 / L3 reference.
- **Filesystem tree + message lifecycle diagrams**: rendered with mermaid.

## Architecture

```
tasks.yaml ──┐
agents.yaml ─┼──> generate.py ──> rendered index.html
template.html┤        │
             │        └─ reads MESH_ROOT (heartbeats, decisions, etc.)
             │        └─ reads FILAMENT_REPO (git log)
             │        └─ reads docker / systemctl / crontab (detection rules)
             └─ string-substitution {{slots}}
```

`generate.py` is stdlib-only Python (PyYAML optional -- it shells out if missing). No build step, no compile, no Node.js.

## Files

```
scripts/canvas-generator/
├── generate.py     # the renderer (stdlib only)
├── template.html   # HTML template with {{slot}} placeholders
├── tasks.yaml      # what to track + how to detect status
└── agents.yaml     # who's on the mesh + how to display them
```

`tasks.yaml` and `agents.yaml` ship as starter templates. Customize them.

## Detection rule types

Each task in `tasks.yaml` has a `detect:` rule that resolves to a status. The available rule types:

| Type | Fields | Detects |
|---|---|---|
| `file_exists` | `path` | File at `path` exists. |
| `dir_exists` | `path` | Directory at `path` exists. |
| `git_commit` | `repo`, `subject_match` | A commit subject in the last 200 of `repo` matches the regex. `repo: filament` resolves to `$FILAMENT_REPO`. |
| `container_mount` | `path`, `containers: []` | Every container in the list has `path` mounted (live) -- partial = in_progress. |
| `file_exists_in_container` | `container`, `path` | `docker exec <container> test -f <path>` succeeds. |
| `glob` | `path` | The glob matches at least one file. |
| `file_contains` | `path`, `text` | File at `path` contains the literal substring `text`. |
| `cron_present` | `pattern` | The literal substring appears in user crontab or `/etc/cron.d/`. |
| `systemd_timer` | `unit` | `systemctl list-timers` shows the unit. |

If a task has `severity: critical` and detection returns `planned`, the dashboard renders it as `vuln` (red badge) instead.

## Adding a new task

Edit `scripts/canvas-generator/tasks.yaml`:

```yaml
tasks:
  - id: my-new-feature
    name: "Description shown in the table"
    layer: L2                       # free-form -- use whatever taxonomy you want
    owner: agent-a                  # who shipped / owns it
    sprint: S5                      # optional milestone label
    detect:
      type: git_commit
      repo: filament
      subject_match: "my new feature"
    notes: "One-line note shown in the rightmost column."
```

Save. Within 15 min the dashboard regenerates and the row appears (or run `python3 scripts/canvas-generator/generate.py` to test immediately).

## Adding an agent to display

Edit `scripts/canvas-generator/agents.yaml`:

```yaml
agents:
  - uri: agent-c@mesh
    role: agent
    description: "What this agent does -- one or two short sentences."
    is_central: false       # set true to highlight as orchestrator
    is_intermittent: false  # set true for mobile / laptop / sleep-prone nodes
```

Liveness comes from `MESH_ROOT/mesh/HEARTBEAT/agent-c.last` -- agents stamp this from a periodic task. <15 min = live, <60 min = stale, otherwise offline. Intermittent agents always render amber regardless of mtime.

## Customizing the template

`template.html` is plain HTML with `{{SLOT}}` placeholders. Available slots:

| Slot | Substituted value |
|---|---|
| `{{PAGE_TITLE}}` | from `CANVAS_TITLE` env (default: "Filament Mesh Intelligence") |
| `{{PAGE_SUBTITLE}}` | from `CANVAS_SUBTITLE` env (default: hostname) |
| `{{LAST_GENERATED}}` | UTC timestamp of this generation |
| `{{COUNT_LIVE}}` `{{COUNT_IN_PROGRESS}}` `{{COUNT_PLANNED}}` `{{COUNT_VULN}}` `{{COUNT_BLOCKED}}` | task counts by status |
| `{{HOST_INBOX_UNREAD}}` `{{HOST_INBOX_READ}}` | counts in `agents/host/inbox/` and `agents/host/inbox/.read/` |
| `{{DECISIONS_COUNT}}` `{{BROADCASTS_COUNT}}` `{{UPGRADES_COUNT}}` | counts in respective `mesh/` subdirs |
| `{{AGENT_CARDS}}` | rendered HTML for the agent grid |
| `{{STATUS_TABLE_ROWS}}` | rendered `<tr>` rows for the status table |
| `{{RECENT_COMMITS}}` | rendered HTML for the commit list |
| `{{MESH_ROOT}}` `{{FILAMENT_REPO}}` | for showing in the footer / diagrams |

Replace anything you don't want, add anything you do. The rendered file is an unmodified copy of `template.html` with substitutions applied -- no other transforms.

## Configuration env vars

| Variable | Default | Purpose |
|---|---|---|
| `MESH_ROOT` | `/opt/filament-mesh` | where the mesh lives |
| `FILAMENT_REPO` | `~/filament` | git repo for `git_commit` detection rules |
| `CANVAS_OUT` | `/var/www/filament-canvas/index.html` | output HTML path |
| `CANVAS_TEMPLATE` | `<script-dir>/template.html` | template file |
| `CANVAS_TASKS` | `<script-dir>/tasks.yaml` | task registry |
| `CANVAS_AGENTS` | `<script-dir>/agents.yaml` | agent registry |
| `CANVAS_TITLE` | "Filament Mesh Intelligence" | `<title>` and h1 |
| `CANVAS_SUBTITLE` | hostname | sidebar subtitle |

## Publishing

The dashboard is a single static HTML file. Any web server works.

### nginx

```nginx
server {
    listen 80;
    server_name dashboard.example.com;
    root /var/www/filament-canvas;
    index index.html;
    add_header Cache-Control "no-store";  # always serve the latest generation
}
```

### Caddy

```caddy
dashboard.example.com {
    root * /var/www/filament-canvas
    file_server
    header Cache-Control "no-store"
}
```

### GitHub Pages

Set `CANVAS_OUT=/path/to/your/pages-repo/index.html`. Add a step that commits + pushes after each generation:

```bash
# wrapper that systemd timer / cron calls instead of generate.py directly
python3 /opt/filament/repo/scripts/canvas-generator/generate.py
cd /path/to/pages-repo
git add index.html && git commit -m "canvas: $(date -uIs)" && git push
```

### S3 + CloudFront

```bash
python3 /opt/filament/repo/scripts/canvas-generator/generate.py
aws s3 cp /var/www/filament-canvas/index.html s3://my-bucket/index.html \
    --cache-control 'no-store, max-age=0'
aws cloudfront create-invalidation --distribution-id ABC123 --paths /index.html
```

## Auto-refresh

The rendered HTML includes a `<script>` that calls `location.reload()` after 15 minutes -- so an open tab picks up new generations without manual refresh. The dashboard re-render cadence is controlled by the systemd timer (default: 15 min) -- match the two if you change it.

## Testing changes

Run the generator manually with a custom output path:

```bash
CANVAS_OUT=/tmp/test-canvas.html python3 /opt/filament/repo/scripts/canvas-generator/generate.py
xdg-open /tmp/test-canvas.html  # or open in browser
```

If a `tasks.yaml` rule is buggy, `generate.py` prints `[warn] detection failed for <id>: <error>` to stderr but keeps going (the task gets `planned` status as a safe default).
