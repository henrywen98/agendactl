# ekctl-mcp

A thin **MCP (stdio) adapter** over the [`ekctl`](../README.md) CLI, so GUI agents that can't run a
shell — **Claude Desktop, Codex desktop** — can read and write macOS Calendar & Reminders.

It adds **no business logic**: each tool builds an `ekctl` argument list, spawns the CLI, and
forwards its bare-JSON stdout. The CLI remains the single source of truth (authorization, time
zones, stable ids, `end > start`, …). If you can run a shell, you don't need this — call `ekctl`
directly (see the [root README](../README.md)).

## Requirements

- macOS 14+, Node.js ≥ 18
- The `ekctl` binary. By default the adapter uses the bundled `../skills/ekctl/scripts/ekctl`;
  override with the `EKCTL_BIN` environment variable, or it falls back to `ekctl` on `PATH`.

## Install

```bash
cd mcp
npm install
```

## Use with Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` and add:

```json
{
  "mcpServers": {
    "ekctl": {
      "command": "node",
      "args": ["/absolute/path/to/ekctl/mcp/index.mjs"],
      "env": {
        "EKCTL_BIN": "/absolute/path/to/ekctl/skills/ekctl/scripts/ekctl"
      }
    }
  }
}
```

Restart Claude Desktop. The `ekctl` tools appear in the tools list.

> **First-run permission:** the first calendar/reminders call triggers the macOS privacy prompt for
> Calendar and Reminders (attributed to the host app). Approve it once. Until then, calls return an
> error whose text starts with `ekctl: … not authorized`.

## Tools

| tool | maps to |
|---|---|
| `calendar_calendars` | `ekctl calendar calendars` |
| `calendar_list_events` | `ekctl calendar list-events` |
| `calendar_create_event` | `ekctl calendar create-event` |
| `calendar_update_event` | `ekctl calendar update-event <id>` |
| `calendar_delete_event` | `ekctl calendar delete-event <id>` |
| `reminders_lists` | `ekctl reminders lists` |
| `reminders_list` | `ekctl reminders list` |
| `reminders_create` | `ekctl reminders create` |
| `reminders_update` | `ekctl reminders update <id>` |
| `reminders_complete` | `ekctl reminders complete <id>` |
| `reminders_delete` | `ekctl reminders delete <id>` |

Successful calls return the CLI's bare JSON. Failures surface the CLI's stderr (first line
`ekctl: <reason>`) as an MCP tool error.
