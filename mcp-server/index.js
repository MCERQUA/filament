#!/usr/bin/env node
/**
 * mesh-mcp-server — exposes JamBot agent mesh as MCP tools.
 *
 * Transport: stdio (Claude Code, Cursor, etc.)
 * Auth: optional MESH_MCP_TOKEN env var (if set, required in Authorization header
 *       for non-stdio transports — ignored for stdio which is process-level trusted)
 *
 * Env:
 *   AGENT_URI    required — the agent identity this server speaks as
 *   MESH_ROOT    optional — defaults to /mnt/agent-mesh
 *   MESH_BIN     optional — path to mesh CLIs dir (default: /usr/local/bin)
 *
 * Tools exposed (15):
 *   mesh_send, mesh_recv, mesh_ack
 *   mesh_queue_enqueue, mesh_queue_claim, mesh_queue_list
 *   mesh_blackboard_post, mesh_blackboard_read
 *   mesh_job_submit, mesh_job_status
 *   mesh_pipeline_create, mesh_pipeline_status
 *   mesh_event_publish, mesh_event_subscribe, mesh_event_poll
 *   mesh_registry_read, mesh_heartbeat_read
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { execFile as _execFile } from "node:child_process";
import { promisify } from "node:util";
import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";

const execFile = promisify(_execFile);

// ── Config ────────────────────────────────────────────────────────────────────
const AGENT_URI = process.env.AGENT_URI;
if (!AGENT_URI || !AGENT_URI.endsWith("@mesh")) {
  process.stderr.write("mesh-mcp-server: AGENT_URI env var required (e.g. AGENT_URI=host@mesh)\n");
  process.exit(3);
}

const MESH_ROOT = process.env.MESH_ROOT || "/mnt/agent-mesh";
const MESH_DIR = `${MESH_ROOT}/mesh`;
const AGENTS_DIR = `${MESH_ROOT}/agents`;
const MESH_BIN = process.env.MESH_BIN || "/usr/local/bin";

const AGENT_NAME = AGENT_URI.replace(/@mesh$/, "");

// ── CLI wrapper ───────────────────────────────────────────────────────────────
async function runCli(bin, args, stdin = "") {
  const env = {
    ...process.env,
    AGENT_URI,
    MESH_ROOT,
  };
  try {
    const { stdout, stderr } = await execFile(`${MESH_BIN}/${bin}`, args, {
      env,
      input: stdin,
      timeout: 30000,
      maxBuffer: 4 * 1024 * 1024,
    });
    return { ok: true, stdout: stdout.trim(), stderr: stderr.trim() };
  } catch (err) {
    return {
      ok: false,
      stdout: (err.stdout || "").trim(),
      stderr: (err.stderr || err.message || "").trim(),
      code: err.code,
    };
  }
}

function textResult(text) {
  return { content: [{ type: "text", text }] };
}

function errResult(msg) {
  return { content: [{ type: "text", text: `ERROR: ${msg}` }], isError: true };
}

// ── Tool definitions ──────────────────────────────────────────────────────────
const TOOLS = [
  {
    name: "mesh_send",
    description: "Send a message to an agent's inbox over the JamBot mesh.",
    inputSchema: {
      type: "object",
      properties: {
        to: { type: "string", description: "Recipient URI e.g. host@mesh" },
        kind: {
          type: "string",
          description: "Message KIND",
          enum: ["ping","message","rfc","decision","announcement","ack","question","urgent",
                 "attachment","task","task-result","bg-job","pipeline-step","heartbeat",
                 "dead-letter","delegate","delegate-result","hitl","hitl-result"],
        },
        subject: { type: "string", description: "Kebab-case subject / topic slug" },
        body: { type: "string", description: "Message body text" },
        replies_to: { type: "string", description: "Prior filename this replies to (optional)" },
        cc: { type: "array", items: { type: "string" }, description: "CC recipients (optional)" },
        urgent: { type: "boolean", description: "Mark as urgent (optional)" },
      },
      required: ["to", "kind", "subject", "body"],
    },
  },
  {
    name: "mesh_recv",
    description: "List unread messages in this agent's inbox.",
    inputSchema: {
      type: "object",
      properties: {
        limit: { type: "number", description: "Max messages to return (default 10)" },
        kind: { type: "string", description: "Filter by KIND (optional)" },
        since: { type: "string", description: "ISO timestamp — show only newer (optional)" },
      },
    },
  },
  {
    name: "mesh_ack",
    description: "Acknowledge (mark as read) a message in the inbox.",
    inputSchema: {
      type: "object",
      properties: {
        filename: { type: "string", description: "Inbox filename to acknowledge" },
      },
      required: ["filename"],
    },
  },
  {
    name: "mesh_queue_enqueue",
    description: "Add a task to a named mesh queue (pending/).",
    inputSchema: {
      type: "object",
      properties: {
        queue: { type: "string", description: "Queue name e.g. 'general'" },
        subject: { type: "string", description: "Task subject slug" },
        body: { type: "string", description: "Task description / instructions" },
      },
      required: ["queue", "subject", "body"],
    },
  },
  {
    name: "mesh_queue_claim",
    description: "Atomically claim the oldest pending task from a queue.",
    inputSchema: {
      type: "object",
      properties: {
        queue: { type: "string", description: "Queue name e.g. 'general'" },
      },
      required: ["queue"],
    },
  },
  {
    name: "mesh_queue_list",
    description: "List pending tasks in a named queue.",
    inputSchema: {
      type: "object",
      properties: {
        queue: { type: "string", description: "Queue name" },
      },
      required: ["queue"],
    },
  },
  {
    name: "mesh_blackboard_post",
    description: "Post a markdown document to the shared mesh blackboard.",
    inputSchema: {
      type: "object",
      properties: {
        namespace: { type: "string", description: "Blackboard namespace e.g. 'my-agent'" },
        filename: { type: "string", description: "Filename within namespace e.g. 'STATE.md'" },
        content: { type: "string", description: "Full markdown content to write" },
      },
      required: ["namespace", "filename", "content"],
    },
  },
  {
    name: "mesh_blackboard_read",
    description: "Read a document from the shared mesh blackboard.",
    inputSchema: {
      type: "object",
      properties: {
        namespace: { type: "string", description: "Blackboard namespace" },
        filename: { type: "string", description: "Filename to read" },
      },
      required: ["namespace", "filename"],
    },
  },
  {
    name: "mesh_job_submit",
    description: "Submit a background job to the mesh job tracker.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Human-readable job name" },
        body: { type: "string", description: "Job description / parameters" },
      },
      required: ["name", "body"],
    },
  },
  {
    name: "mesh_job_status",
    description: "Check status of a background job by job ID.",
    inputSchema: {
      type: "object",
      properties: {
        job_id: { type: "string", description: "Job ID e.g. bg-a1b2c3d4" },
      },
      required: ["job_id"],
    },
  },
  {
    name: "mesh_pipeline_create",
    description: "Create a multi-step mesh pipeline and dispatch step 0.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Pipeline name" },
        steps: {
          type: "array",
          description: "Pipeline steps — each is 'stepname:agent@mesh:on_success@mesh:on_failure@mesh'",
          items: { type: "string" },
        },
      },
      required: ["name", "steps"],
    },
  },
  {
    name: "mesh_pipeline_status",
    description: "Check status of a mesh pipeline.",
    inputSchema: {
      type: "object",
      properties: {
        pipeline_id: { type: "string", description: "Pipeline ID e.g. pl-a1b2c3d4" },
      },
      required: ["pipeline_id"],
    },
  },
  {
    name: "mesh_event_publish",
    description: "Publish an event to a mesh pub/sub topic.",
    inputSchema: {
      type: "object",
      properties: {
        topic: { type: "string", description: "Topic name e.g. 'mesh-system.alerts'" },
        body: { type: "string", description: "Event body text" },
        ttl: { type: "number", description: "Time-to-live in seconds (optional)" },
      },
      required: ["topic", "body"],
    },
  },
  {
    name: "mesh_event_subscribe",
    description: "Subscribe this agent to a mesh event topic.",
    inputSchema: {
      type: "object",
      properties: {
        topic: { type: "string", description: "Topic name" },
      },
      required: ["topic"],
    },
  },
  {
    name: "mesh_event_poll",
    description: "Poll unprocessed events on a topic for this agent.",
    inputSchema: {
      type: "object",
      properties: {
        topic: { type: "string", description: "Topic name" },
        limit: { type: "number", description: "Max events to return (default 50)" },
      },
      required: ["topic"],
    },
  },
  {
    name: "mesh_registry_read",
    description: "Read the mesh agent registry (who is on the mesh).",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "mesh_heartbeat_read",
    description: "Check liveness of a mesh agent via its heartbeat file.",
    inputSchema: {
      type: "object",
      properties: {
        agent: { type: "string", description: "Agent name e.g. residential-laptop" },
      },
      required: ["agent"],
    },
  },
];

// ── Tool handlers ─────────────────────────────────────────────────────────────
async function handleTool(name, args) {
  switch (name) {
    case "mesh_send": {
      const cliArgs = [
        "--to", args.to,
        "--kind", args.kind,
        "--subject", args.subject,
      ];
      if (args.replies_to) cliArgs.push("--replies-to", args.replies_to);
      if (args.urgent) cliArgs.push("--urgent");
      for (const cc of (args.cc || [])) cliArgs.push("--cc", cc);
      const r = await runCli("mesh-send", cliArgs, args.body);
      if (!r.ok && r.code === 2) return errResult("urgent rate-limited (1/hr)");
      if (!r.ok) return errResult(r.stderr || `exit ${r.code}`);
      return textResult(`Sent → ${r.stdout}`);
    }

    case "mesh_recv": {
      const cliArgs = [];
      if (args.limit) cliArgs.push("--limit", String(args.limit));
      if (args.kind) cliArgs.push("--kind", args.kind);
      if (args.since) cliArgs.push("--since", args.since);
      const r = await runCli("mesh-recv", cliArgs);
      if (!r.ok && r.code === 2) return textResult("(inbox empty)");
      if (!r.ok) return errResult(r.stderr);
      return textResult(r.stdout || "(no messages)");
    }

    case "mesh_ack": {
      const r = await runCli("mesh-ack", [args.filename]);
      if (!r.ok) return errResult(r.stderr);
      return textResult(`Acked: ${args.filename}`);
    }

    case "mesh_queue_enqueue": {
      // Use mesh-send to self as a task, then copy to queue
      const queueDir = `${MESH_DIR}/QUEUE/${args.queue}/pending`;
      const cliArgs = [
        "--to", AGENT_URI,
        "--kind", "task",
        "--subject", args.subject,
      ];
      const r = await runCli("mesh-send", cliArgs, args.body);
      if (!r.ok) return errResult(r.stderr);
      // The file landed in our inbox — move to queue pending
      const inboxFile = r.stdout; // absolute path
      const basename = path.basename(inboxFile);
      try {
        const { execFile: ef } = await import("node:child_process");
        const { promisify: p } = await import("node:util");
        const mkdirp = p(ef);
        await mkdirp("bash", ["-c", `mkdir -p '${queueDir}' && mv '${inboxFile}' '${queueDir}/${basename}'`]);
      } catch (_) {}
      // Direct approach using fs
      const { rename, mkdir } = await import("node:fs/promises");
      try {
        await mkdir(queueDir, { recursive: true });
        await rename(inboxFile, `${queueDir}/${basename}`);
      } catch (e) {
        return errResult(`moved to inbox but queue move failed: ${e.message}`);
      }
      return textResult(`Enqueued: ${basename} in queue '${args.queue}'`);
    }

    case "mesh_queue_claim": {
      const r = await runCli("mesh-task-claim", ["claim", args.queue]);
      if (!r.ok && r.code === 1) return textResult("(no pending tasks in queue)");
      if (!r.ok) return errResult(r.stderr);
      return textResult(`Claimed: ${r.stdout}`);
    }

    case "mesh_queue_list": {
      const r = await runCli("mesh-task-claim", ["list", "--queue", args.queue]);
      if (!r.ok && r.code === 1) return textResult(`(queue '${args.queue}' is empty)`);
      if (!r.ok) return errResult(r.stderr);
      return textResult(r.stdout || "(empty)");
    }

    case "mesh_blackboard_post": {
      const targetDir = `${MESH_DIR}/BLACKBOARD/${args.namespace}`;
      const { mkdir, writeFile } = await import("node:fs/promises");
      try {
        await mkdir(targetDir, { recursive: true });
        const fp = `${targetDir}/${args.filename}`;
        const tmp = `${fp}.tmp`;
        await writeFile(tmp, args.content, "utf8");
        const { rename } = await import("node:fs/promises");
        await rename(tmp, fp);
        return textResult(`Posted to BLACKBOARD/${args.namespace}/${args.filename}`);
      } catch (e) {
        return errResult(e.message);
      }
    }

    case "mesh_blackboard_read": {
      const fp = `${MESH_DIR}/BLACKBOARD/${args.namespace}/${args.filename}`;
      try {
        const content = await readFile(fp, "utf8");
        return textResult(content);
      } catch (e) {
        if (e.code === "ENOENT") return textResult(`(not found: BLACKBOARD/${args.namespace}/${args.filename})`);
        return errResult(e.message);
      }
    }

    case "mesh_job_submit": {
      const r = await runCli("mesh-jobs", ["submit", "--name", args.name], args.body);
      if (!r.ok) return errResult(r.stderr);
      return textResult(r.stdout);
    }

    case "mesh_job_status": {
      const r = await runCli("mesh-jobs", ["show", args.job_id]);
      if (!r.ok && r.code === 1) return textResult(`Job ${args.job_id} not found`);
      if (!r.ok) return errResult(r.stderr);
      return textResult(r.stdout);
    }

    case "mesh_pipeline_create": {
      const cliArgs = ["create", args.name];
      for (const step of args.steps) cliArgs.push("--step", step);
      const r = await runCli("mesh-pipeline", cliArgs);
      if (!r.ok) return errResult(r.stderr);
      return textResult(r.stdout);
    }

    case "mesh_pipeline_status": {
      const r = await runCli("mesh-pipeline", ["status", args.pipeline_id]);
      if (!r.ok && r.code === 1) return textResult(`Pipeline ${args.pipeline_id} not found`);
      if (!r.ok) return errResult(r.stderr);
      return textResult(r.stdout);
    }

    case "mesh_event_publish": {
      const cliArgs = ["publish", args.topic, "--body", args.body];
      if (args.ttl) cliArgs.push("--ttl", String(args.ttl));
      const r = await runCli("mesh-event", cliArgs);
      if (!r.ok) return errResult(r.stderr);
      return textResult(r.stdout);
    }

    case "mesh_event_subscribe": {
      const r = await runCli("mesh-event", ["subscribe", args.topic]);
      if (!r.ok) return errResult(r.stderr);
      return textResult(r.stdout);
    }

    case "mesh_event_poll": {
      const cliArgs = ["poll", args.topic];
      if (args.limit) cliArgs.push("--limit", String(args.limit));
      const r = await runCli("mesh-event", cliArgs);
      if (!r.ok && r.code === 1) return textResult(`(no new events on topic '${args.topic}')`);
      if (!r.ok) return errResult(r.stderr);
      return textResult(r.stdout);
    }

    case "mesh_registry_read": {
      const fp = `${MESH_DIR}/REGISTRY.md`;
      try {
        const content = await readFile(fp, "utf8");
        return textResult(content);
      } catch (e) {
        if (e.code === "ENOENT") return textResult("(REGISTRY.md not found — run mesh-on first)");
        return errResult(e.message);
      }
    }

    case "mesh_heartbeat_read": {
      const fp = `${AGENTS_DIR}/${args.agent}/status/heartbeat.txt`;
      try {
        const [content, info] = await Promise.all([
          readFile(fp, "utf8"),
          stat(fp),
        ]);
        const ageSec = Math.round((Date.now() - info.mtimeMs) / 1000);
        const liveness = ageSec < 120 ? "ALIVE" : ageSec < 600 ? "STALE" : "DEAD";
        return textResult(`[${liveness} — ${ageSec}s ago]\n\n${content}`);
      } catch (e) {
        if (e.code === "ENOENT") return textResult(`(no heartbeat file for agent '${args.agent}')`);
        return errResult(e.message);
      }
    }

    default:
      return errResult(`Unknown tool: ${name}`);
  }
}

// ── Server setup ──────────────────────────────────────────────────────────────
const server = new Server(
  { name: "jambot-mesh", version: "1.0.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS,
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const { name, arguments: args = {} } = req.params;
  try {
    return await handleTool(name, args);
  } catch (err) {
    return errResult(err.message || String(err));
  }
});

// ── Start ─────────────────────────────────────────────────────────────────────
const transport = new StdioServerTransport();
await server.connect(transport);
process.stderr.write(`mesh-mcp-server: ready (agent=${AGENT_URI} mesh=${MESH_ROOT})\n`);
