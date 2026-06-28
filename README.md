# agendactl

[![CI](https://github.com/henrywen98/agendactl/actions/workflows/ci.yml/badge.svg)](https://github.com/henrywen98/agendactl/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)

**An installable agent skill that lets any AI agent read & write macOS Calendar and Reminders.** The skill bundles a single, auditable Swift CLI over Apple's [EventKit](https://developer.apple.com/documentation/eventkit) — `git clone` it into your agent's skills directory and it just works. **No MCP, no servers, no arbitrary code execution.**

> *"Remind me to send the report at 9am tomorrow."* · *"What meetings do I have this week?"* · *"Mark that one done."*
> The agent only ever calls `agendactl <app> <cmd> --flag …` and passes arguments — it never writes code, never touches EventKit, never gets an escape hatch.

[English] · [中文](./README.zh-CN.md)

---

## In action

```text
you  ▸ what meetings do I have this week?

agent ▸ agendactl calendar list-events --from 2026-06-29T00:00:00 --to 2026-07-06T00:00:00
      ← {"_iso":"2026-06-29","items":[
           {"summary":"Funda Sales & Engineer sync","calendar":"Work",
            "start":"2026-07-02T01:00:00Z","end":"2026-07-02T01:30:00Z"} ]}
      This week you have one meeting:
        • Thu 07-02, 09:00–09:30 — Funda Sales & Engineer sync (Work)

you  ▸ remind me to send the report at 9am tomorrow

agent ▸ agendactl reminders create --list Tasks --name "Send report" --due 2026-06-30T09:00:00
      ← {"id":"…","name":"Send report","list":"Tasks","due":"2026-06-30T01:00:00.000Z"}
      Done — added "Send report" to Tasks, due tomorrow 09:00.
```

The agent reads the SKILL.md, calls `agendactl` with arguments, parses the JSON, and answers
in plain language. It never writes code or touches EventKit directly.

## What it is

A [Claude/agent **Skill**](https://github.com/VoltAgent/awesome-agent-skills): a folder with a `SKILL.md` (so the agent knows when and how to use it) plus a **prebuilt, signed universal binary** in `scripts/`. Install the folder, and any skill-aware agent — Claude Code, Codex, Cursor, Gemini CLI, pi — can manage your Calendar and Reminders. The same binary is a normal CLI you can run yourself or from cron/scripts.

## Why a skill instead of an MCP server?

There are many MCP servers (and a few CLIs) for Apple Calendar/Reminders. `agendactl` takes a different shape:

| | `agendactl` (skill + CLI) | typical Apple-app MCP server |
|---|---|---|
| Install | `git clone` a folder into your skills dir | configure an MCP server + its runtime |
| Runtime to install | **none** — a bundled signed universal binary | Node / Python / bun |
| Works with shell agents (Claude Code, Cursor, pi, cron, scripts) | ✅ directly | ❌ needs an MCP host |
| Arbitrary code execution handed to the agent | ❌ none — arguments only, capability capped at the CLI surface | varies |
| Auditable surface | one Swift file (~350 lines) you can read end-to-end | server + dependencies |
| Backend | native EventKit (stable ids, millisecond queries) | EventKit / AppleScript / JXA |

> Scope is deliberate: shell-capable agents only. A GUI-only client that can't run a shell (e.g. Claude Desktop) is out of scope by design — that's the MCP servers' niche, and this isn't trying to be one.

The design wasn't arrived at lightly — it's the result of reversing an earlier "JXA + escape-hatch" architecture under scrutiny. Every reversal, with measurements, is in [`docs/adr/`](./docs/adr/).

## Install

**Requirements:** macOS 14+ (Sonoma or later), Apple Silicon or Intel. A prebuilt universal binary is committed at `skills/agendactl/scripts/agendactl`.

**As an agent skill** (recommended) — copy the self-contained skill into your agent's skills directory:
```bash
git clone https://github.com/henrywen98/agendactl.git
cp -R agendactl/skills/agendactl ~/.agents/skills/agendactl    # shared agent-skills dir (pi, OpenCode, …)
# or your agent's own dir: ~/.claude/skills/agendactl (Claude Code) · ~/.codex/skills/agendactl (Codex)
```
The skill bundles the binary, so installing the skill is all that's needed — no `PATH` setup required.
A skill-aware agent resolves the binary at `scripts/agendactl` relative to the skill's own directory. (`git clone` does not quarantine files, so the binary runs as-is. If you downloaded a ZIP from a browser, clear quarantine once: `xattr -dr com.apple.quarantine ~/.claude/skills/agendactl/scripts/agendactl`.)

**As a plain CLI** (for your own scripts / cron) — put it on your `PATH`:
```bash
ln -s "$(pwd)/agendactl/skills/agendactl/scripts/agendactl" /opt/homebrew/bin/agendactl
agendactl --help
```

**Rebuild from source** (optional, for audit or a fresh build):
```bash
./skills/agendactl/scripts/build.sh        # 2× swiftc → lipo → codesign (universal2, ad-hoc)
```

## Permissions (one-time)

EventKit is gated by macOS privacy (TCC). On first use, agendactl triggers the system prompt for **Calendar** and **Reminders** — approve it once in a logged-in GUI session (Calendar and Reminders are separate buckets). If not yet authorized, agendactl exits with code `3` and a hint. This step is inherent to any tool touching these apps and can't be skipped headlessly.

## Usage

```bash
agendactl --help                 # overview
agendactl reminders --help       # reminders commands
agendactl calendar --help        # calendar commands

# "Remind me to send the report at 9am tomorrow"
agendactl reminders create --list "Tasks" --name "Send report" --due "2026-06-29T09:00:00"
# → {"id":"…","name":"Send report","list":"Tasks","due":"2026-06-29T01:00:00.000Z", …}

# "What meetings do I have this week?"
agendactl calendar list-events --from "2026-06-29T00:00:00" --to "2026-07-06T00:00:00"

# "Move that reminder to the day after"
agendactl reminders update <id> --due "2026-07-01T09:00:00"
```

**Contract** (so agents parse reliably):

- Success → exit `0`, stdout is **JSON**. Every response carries `_at` / `_tz` / `_iso` / `_note` meta at the top level: list responses put the array under `items` (`{…meta, "items": [...]}`); write responses merge the meta keys onto the result fields. Failure → exit non-zero, stderr first line `agendactl: <reason>`.
- Exit codes: `0` ok · `1` usage/arg error · `2` not found (incl. duplicate-name ambiguity) · `3` not authorized · `4` runtime error.
- Dates: input ISO 8601 (no tz suffix = local time); output UTC ISO. Every response carries `_at` / `_tz` / `_iso` / `_note` meta — use `._iso` to resolve "today".
- Containers (calendars/lists) are addressed by **name**; duplicates return exit `2` + candidates, disambiguate with `--index <n>`.

## Commands

```
agendactl calendar
  calendars
  list-events  [--calendar <name>] [--from <iso>] [--to <iso>] [--limit <n>]
  create-event --calendar <name> --summary <text> --start <iso> --end <iso>
               [--location <text>] [--notes <text>] [--all-day]
  update-event <id> [--summary] [--start] [--end] [--location] [--notes]
  delete-event <id>

agendactl reminders
  lists
  list     [--list <name>] [--status incomplete|completed|all] [--due today|<iso>] [--limit <n>]
  create   --list <name> --name <text> [--notes <text>] [--due <iso>] [--priority 0-9]
  update   <id> [--name] [--notes] [--due] [--priority] [--complete]
  complete <id>
  delete   <id>
```

## How it works

```
skill-aware agent (Claude Code / Codex / Cursor / Gemini CLI / pi)
  └─ reads skills/agendactl/SKILL.md, calls:  agendactl <app> <cmd> --flag …  (args only)
        │ runs the bundled binary
        ▼
  agendactl (Swift, EventKit) — arg validation, auth, time zones, stable ids, end>start
        ▼
  macOS Calendar / Reminders (EKEvent / EKReminder) ← iCloud sync
```

The CLI is the single source of truth: validation, authorization, time zones, stable ids, and business rules all live inside one Swift file.

- **[ARCHITECTURE.md](./ARCHITECTURE.md)** — design contract (read this first)
- **[docs/adr/](./docs/adr/)** — decision records (ADR-0001..0012, the v1→v2 evolution)
- **[docs/glossary.md](./docs/glossary.md)** — domain language

## Status

- ✅ CLI runtime (`skills/agendactl/scripts/agendactl`, EventKit, Calendar + Reminders CRUD)
- ✅ Agent skill (`skills/agendactl/SKILL.md`)
- ✅ Tests: smoke (no-auth contract) and round-trip (EventKit CRUD, `__probe__`-tagged, idempotent, self-cleaning)
- 🔜 Notes (needs a JXA backend) · Mail / Contacts · scheduled automation

```bash
./tests/smoke.sh        # contract checks, no authorization / no data written
./tests/roundtrip.sh    # full EventKit CRUD round-trip (needs TCC auth; writes & cleans __probe__ items)
```

## License

[MIT](./LICENSE)
