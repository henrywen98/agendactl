# ekctl

**Control macOS Calendar & Reminders from any AI agent** — a single, auditable Swift CLI over Apple's [EventKit](https://developer.apple.com/documentation/eventkit), shipped as an agent skill. **No MCP required. No arbitrary code execution.**

> *"Remind me to send the report at 9am tomorrow."* · *"What meetings do I have this week?"* · *"Mark that one done."*
> The agent only ever calls `ekctl <app> <cmd> --flag …` and passes arguments — it never writes code, never touches EventKit, never gets an escape hatch.

[English] · [中文](./README.zh-CN.md)

---

## Why another macOS Calendar/Reminders tool?

There are many MCP servers for Apple Reminders/Calendar. `ekctl` takes the opposite bet: a **thin, parameterized CLI** that any agent drives with arguments, plus an *optional* MCP adapter for GUI clients that can't run a shell.

| | `ekctl` | typical Apple-app MCP server |
|---|---|---|
| Agent interface | calls a CLI with flags | calls MCP tools |
| Works without an MCP client | ✅ any agent that can run `bash` (Claude Code, Cursor, pi, scripts, cron) | ❌ needs an MCP host |
| Works *with* Claude Desktop / Codex | ✅ via optional `mcp/` adapter | ✅ |
| Arbitrary code execution given to the agent | ❌ none — args only, capability capped at CLI surface | varies |
| Auditable surface | one Swift file (~350 lines) you can read end-to-end | server + deps |
| Runtime to install | a single signed binary (no Node/Python) | Node / Python / bun |
| Backend | native EventKit (stable ids, millisecond queries) | EventKit / AppleScript / JXA |

The design wasn't arrived at lightly — it's the result of reversing an earlier "JXA + escape-hatch" architecture under scrutiny. Every reversal, with measurements, is in [`docs/adr/`](./docs/adr/).

## Install

**Requirements:** macOS 14+ (Sonoma or later), Apple Silicon or Intel. A prebuilt universal binary is committed at `skills/ekctl/scripts/ekctl`.

```bash
git clone https://github.com/henrywen98/ekctl.git
cd ekctl
```

`git clone` does **not** quarantine files, so the binary runs as-is. (If you downloaded a ZIP from a browser, clear quarantine once: `xattr -dr com.apple.quarantine skills/ekctl/scripts/ekctl`.)

Pick how you want to use it:

**As a CLI** (Claude Code, Cursor, pi, your own scripts) — put it on your `PATH`:
```bash
ln -s "$(pwd)/skills/ekctl/scripts/ekctl" /opt/homebrew/bin/ekctl
ekctl --help
```

**As an agent skill** — copy the self-contained skill into your agent's skills directory:
```bash
cp -R skills/ekctl ~/.claude/skills/ekctl      # Claude Code; or .pi/skills, etc.
```
The skill bundles the binary, so installing the skill is all that's needed.

**As an MCP server** (Claude Desktop, Codex desktop) — see [`mcp/`](./mcp/).

**Rebuild from source** (optional, for audit or a fresh build):
```bash
./skills/ekctl/scripts/build.sh        # 2× swiftc → lipo → codesign (universal2, ad-hoc)
```

## Permissions (one-time)

EventKit is gated by macOS privacy (TCC). On first use, ekctl triggers the system prompt for **Calendar** and **Reminders** — approve it once in a logged-in GUI session (Calendar and Reminders are separate buckets). If not yet authorized, ekctl exits with code `3` and a hint. This step is inherent to any tool touching these apps and can't be skipped headlessly.

## Usage

```bash
ekctl --help                 # overview
ekctl reminders --help       # reminders commands
ekctl calendar --help        # calendar commands

# "Remind me to send the report at 9am tomorrow"
ekctl reminders create --list "Tasks" --name "Send report" --due "2026-06-29T09:00:00"
# → {"id":"…","name":"Send report","list":"Tasks","due":"2026-06-29T01:00:00.000Z", …}

# "What meetings do I have this week?"
ekctl calendar list-events --from "2026-06-29T00:00:00" --to "2026-07-06T00:00:00"

# "Move that reminder to the day after"
ekctl reminders update <id> --due "2026-07-01T09:00:00"
```

**Contract** (so agents parse reliably):

- Success → exit `0`, stdout is **bare JSON** (no envelope). Failure → exit non-zero, stderr first line `ekctl: <reason>`.
- Exit codes: `0` ok · `1` usage/arg error · `2` not found (incl. duplicate-name ambiguity) · `3` not authorized · `4` runtime error.
- Dates: input ISO 8601 (no tz suffix = local time); output UTC ISO. Every response carries `_at` / `_tz` / `_iso` / `_note` meta — use `._iso` to resolve "today".
- Containers (calendars/lists) are addressed by **name**; duplicates return exit `2` + candidates, disambiguate with `--index <n>`.

## Commands

```
ekctl calendar
  calendars
  list-events  [--calendar <name>] [--from <iso>] [--to <iso>] [--limit <n>]
  create-event --calendar <name> --summary <text> --start <iso> --end <iso>
               [--location <text>] [--notes <text>] [--all-day]
  update-event <id> [--summary] [--start] [--end] [--location] [--notes]
  delete-event <id>

ekctl reminders
  lists
  list     [--list <name>] [--status incomplete|completed|all] [--due today|<iso>] [--limit <n>]
  create   --list <name> --name <text> [--notes <text>] [--due <iso>] [--priority 0-9]
  update   <id> [--name] [--notes] [--due] [--priority] [--complete]
  complete <id>
  delete   <id>
```

## How it works

```
AI agent  ──(bash: ekctl <app> <cmd> --flag …, args only)──▶  ekctl (Swift, EventKit)  ──▶  macOS Calendar / Reminders
GUI agent ──(MCP tools)──▶  mcp/ adapter  ──▶  ekctl  ──▶  …
```

The CLI is the single source of truth: argument validation, authorization, time zones, stable ids, and business rules (e.g. `end > start`) all live inside it. The optional MCP adapter is a thin forwarder — it adds no business logic.

- **[ARCHITECTURE.md](./ARCHITECTURE.md)** — design contract (read this first)
- **[docs/adr/](./docs/adr/)** — decision records (ADR-0001..0012, the v1→v2 evolution)
- **[docs/glossary.md](./docs/glossary.md)** — domain language

## Status

- ✅ CLI runtime (`skills/ekctl/scripts/ekctl`, EventKit, Calendar + Reminders CRUD)
- ✅ Agent skill (`skills/ekctl/SKILL.md`)
- ✅ Black-box round-trip tests (`tests/roundtrip.sh`, `__probe__`-tagged, idempotent, self-cleaning)
- 🔜 MCP adapter (`mcp/`) · Notes (needs a JXA backend) · Mail / Contacts · scheduled automation

Tests write `__probe__`-tagged temporary items into the first writable list/calendar and delete them again:
```bash
./tests/roundtrip.sh
```

## License

[MIT](./LICENSE)
