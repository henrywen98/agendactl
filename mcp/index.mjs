#!/usr/bin/env node
//
// ekctl-mcp — a thin stdio MCP adapter over the `ekctl` CLI.
//
// It adds NO business logic: every tool builds an `ekctl` argument list, spawns
// the CLI, and forwards its bare-JSON stdout. The CLI stays the single source of
// truth (auth, time zones, stable ids, end>start, …). This adapter exists only so
// GUI agents that can't run a shell (Claude Desktop, Codex desktop) can reach it.
//
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { ListToolsRequestSchema, CallToolRequestSchema } from "@modelcontextprotocol/sdk/types.js";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { existsSync } from "node:fs";

// Resolve the ekctl binary: $EKCTL_BIN → bundled copy → `ekctl` on PATH.
const here = dirname(fileURLToPath(import.meta.url));
const bundled = resolve(here, "..", "skills", "ekctl", "scripts", "ekctl");
const BIN = process.env.EKCTL_BIN || (existsSync(bundled) ? bundled : "ekctl");

function runEkctl(args) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(BIN, args, { stdio: ["ignore", "pipe", "pipe"] });
    let out = "", err = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("error", reject);
    child.on("close", (code) => resolvePromise({ code, out, err }));
  });
}

// ---- arg builders ----
const flag = (a, name, v) => { if (v !== undefined && v !== null && v !== "") a.push(name, String(v)); };
const bool = (a, name, v) => { if (v === true) a.push(name); };

// Each tool: name, description, JSON-Schema inputSchema, and toArgs(input) → ekctl argv.
const TOOLS = [
  {
    name: "calendar_calendars",
    description: "List all macOS calendars (name, id, writable). Run before any calendar write.",
    inputSchema: { type: "object", properties: {} },
    toArgs: () => ["calendar", "calendars"],
  },
  {
    name: "calendar_list_events",
    description: "List calendar events (default next 30 days). Returns a JSON array.",
    inputSchema: {
      type: "object",
      properties: {
        calendar: { type: "string", description: "calendar name (optional)" },
        from: { type: "string", description: "start ISO 8601, e.g. 2026-06-29T00:00:00 (no tz suffix = local)" },
        to: { type: "string", description: "end ISO 8601" },
        limit: { type: "integer", description: "max items" },
      },
    },
    toArgs: (i) => { const a = ["calendar", "list-events"]; flag(a, "--calendar", i.calendar); flag(a, "--from", i.from); flag(a, "--to", i.to); flag(a, "--limit", i.limit); return a; },
  },
  {
    name: "calendar_create_event",
    description: "Create a calendar event. --end must be later than --start.",
    inputSchema: {
      type: "object",
      properties: {
        calendar: { type: "string", description: "calendar name" },
        summary: { type: "string", description: "event title" },
        start: { type: "string", description: "start ISO 8601 (no tz suffix = local)" },
        end: { type: "string", description: "end ISO 8601, later than start" },
        location: { type: "string" },
        notes: { type: "string" },
        allDay: { type: "boolean" },
      },
      required: ["calendar", "summary", "start", "end"],
    },
    toArgs: (i) => { const a = ["calendar", "create-event"]; flag(a, "--calendar", i.calendar); flag(a, "--summary", i.summary); flag(a, "--start", i.start); flag(a, "--end", i.end); flag(a, "--location", i.location); flag(a, "--notes", i.notes); bool(a, "--all-day", i.allDay); return a; },
  },
  {
    name: "calendar_update_event",
    description: "Update a calendar event by id. Fields not given stay unchanged.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" },
        summary: { type: "string" },
        start: { type: "string" },
        end: { type: "string" },
        location: { type: "string" },
        notes: { type: "string" },
      },
      required: ["id"],
    },
    toArgs: (i) => { const a = ["calendar", "update-event", i.id]; flag(a, "--summary", i.summary); flag(a, "--start", i.start); flag(a, "--end", i.end); flag(a, "--location", i.location); flag(a, "--notes", i.notes); return a; },
  },
  {
    name: "calendar_delete_event",
    description: "Delete a calendar event by id.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
    toArgs: (i) => ["calendar", "delete-event", i.id],
  },
  {
    name: "reminders_lists",
    description: "List all reminder lists (name, id, writable). Run before any reminders write.",
    inputSchema: { type: "object", properties: {} },
    toArgs: () => ["reminders", "lists"],
  },
  {
    name: "reminders_list",
    description: "List reminders (default incomplete). Returns a JSON array.",
    inputSchema: {
      type: "object",
      properties: {
        list: { type: "string", description: "list name (optional)" },
        status: { type: "string", enum: ["incomplete", "completed", "all"] },
        due: { type: "string", description: "'today' or an ISO date (upper bound)" },
        limit: { type: "integer" },
      },
    },
    toArgs: (i) => { const a = ["reminders", "list"]; flag(a, "--list", i.list); flag(a, "--status", i.status); flag(a, "--due", i.due); flag(a, "--limit", i.limit); return a; },
  },
  {
    name: "reminders_create",
    description: "Create a reminder. priority 0=none 1-4=high 5=medium 6-9=low.",
    inputSchema: {
      type: "object",
      properties: {
        list: { type: "string", description: "list name" },
        name: { type: "string", description: "reminder text" },
        notes: { type: "string" },
        due: { type: "string", description: "ISO 8601 (no tz suffix = local)" },
        priority: { type: "integer", minimum: 0, maximum: 9 },
      },
      required: ["list", "name"],
    },
    toArgs: (i) => { const a = ["reminders", "create"]; flag(a, "--list", i.list); flag(a, "--name", i.name); flag(a, "--notes", i.notes); flag(a, "--due", i.due); flag(a, "--priority", i.priority); return a; },
  },
  {
    name: "reminders_update",
    description: "Update a reminder by id. Fields not given stay unchanged. Set complete=true to mark done.",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" },
        name: { type: "string" },
        notes: { type: "string" },
        due: { type: "string" },
        priority: { type: "integer", minimum: 0, maximum: 9 },
        complete: { type: "boolean" },
      },
      required: ["id"],
    },
    toArgs: (i) => { const a = ["reminders", "update", i.id]; flag(a, "--name", i.name); flag(a, "--notes", i.notes); flag(a, "--due", i.due); flag(a, "--priority", i.priority); bool(a, "--complete", i.complete); return a; },
  },
  {
    name: "reminders_complete",
    description: "Mark a reminder complete by id.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
    toArgs: (i) => ["reminders", "complete", i.id],
  },
  {
    name: "reminders_delete",
    description: "Delete a reminder by id.",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
    toArgs: (i) => ["reminders", "delete", i.id],
  },
];

const byName = new Map(TOOLS.map((t) => [t.name, t]));

const server = new Server(
  { name: "ekctl-mcp", version: "0.1.0" },
  { capabilities: { tools: {} } }
);

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
}));

server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const tool = byName.get(req.params.name);
  if (!tool) return { content: [{ type: "text", text: `ekctl-mcp: unknown tool ${req.params.name}` }], isError: true };
  const args = tool.toArgs(req.params.arguments ?? {});
  let res;
  try {
    res = await runEkctl(args);
  } catch (e) {
    return { content: [{ type: "text", text: `ekctl-mcp: failed to run ekctl (${BIN}): ${e.message}` }], isError: true };
  }
  if (res.code === 0) {
    // Forward the CLI's bare JSON verbatim.
    return { content: [{ type: "text", text: res.out.trim() }] };
  }
  // Non-zero exit → surface stderr (first line is `ekctl: <reason>`) as an MCP error.
  return { content: [{ type: "text", text: (res.err.trim() || `ekctl exited ${res.code}`) }], isError: true };
});

const transport = new StdioServerTransport();
await server.connect(transport);
