---
name: agendactl
description: >-
  Read and write macOS Calendar events AND Reminders/to-dos through the bundled `agendactl` CLI
  (EventKit). Use this skill whenever the user wants to add, list, change, or delete a calendar
  event or a reminder; check what is on a given day or this week; mark a to-do done; reschedule
  something; change a meeting's time or location; or filter by date / list / calendar — even when
  the words "calendar" or "reminder" are not said. Covers "remind me to send the report",
  "what meetings do I have this week", "move the standup to Wednesday", "mark it done",
  "set this to high priority", "cancel that event". Two domains, one CLI — route carefully:
  CALENDAR = events with a start/end interval (meetings; NO "complete" concept) → `agendactl calendar …`;
  REMINDERS = to-dos with a due date that can be completed → `agendactl reminders …`.
  "Remind me to X" / "mark complete" / "to-do" / "what do I have to do today" → reminders;
  "add a meeting" / "3–4pm" / "this week's schedule" / "cancel that event" → calendar.
  Only ever call the CLI with arguments — never write scripts, never touch EventKit or system APIs.
---

# macOS Calendar & Reminders automation (agendactl)

Drive macOS Calendar and Reminders by calling the `agendactl` CLI. **Only call commands and pass
arguments** — authorization, time zones, stable ids, and validation (`end > start`, etc.) are all
handled inside the CLI. Whatever the CLI does not expose is simply not available; do not route
around it by writing scripts.

## Running agendactl

The binary ships **inside this skill** at `scripts/agendactl`. Resolve it in this order:

1. If `agendactl` is on `PATH`, just call `agendactl`.
2. Otherwise, run the bundled binary using **this skill's own directory** — the absolute path of the
   folder this `SKILL.md` was loaded from — e.g. `~/.claude/skills/agendactl/scripts/agendactl` or
   `~/.pi/agent/skills/agendactl/scripts/agendactl`. **Resolve `scripts/agendactl` against the skill
   directory, NOT against the current working directory** (the cwd is usually the user's project, not
   this skill). No install step beyond having the skill folder is required.

Subcommands and flags are identical either way. Do not `find` the whole disk for it, and do not
substitute another tool (Google Calendar, a separate task app): this machine's Calendar/Reminders
data lives only in macOS, and only `agendactl` reads it.

## Design notes (read first)

- **Responses carry meta.** Every `agendactl` response has `_at` / `_tz` / `_iso` / `_note` at the top
  level. `_at` is the **moment the CLI ran** (meta), NOT the item's `start`/`end`/`due` time. The
  underscore prefix marks meta; bare names are data. `_note` spells this out.
- **Get "today" from the response, not from context.** When the user says "today / tonight /
  tomorrow", read the date from any `agendactl` response's `._iso` field (e.g. `2026-06-29`). Do not
  call `date` for it and do not guess — the host's reported "today" can be stale or wrong, and
  writing an event to yesterday drops it out of the calendar view.
- **CLI-only.** Only call `agendactl <app> …` with arguments. Never write code, never touch
  JXA/EventKit. If something is not reachable, say "not supported yet" rather than inventing it.
- **List the containers before writing.** Run `calendars` / `lists` first to get the real
  container names (the response also returns `_iso`, handy for building "today").

## Calendar vs Reminders — route correctly

- **Concept.** CALENDAR = a schedule entry (meeting/event, has a `start`/`end` interval, has
  location/notes, has **no** "complete" concept — it exists or it is deleted). REMINDERS = a to-do
  (has a `due` time, **can be completed**).
- **Go to calendar when** the user says "add a meeting" / "what's on this week" / "3–4pm" (an
  interval) / "cancel that event" / anything with a start–end span.
- **Go to reminders when** the user says "remind me" / "to-do" / "mark complete" / "what do I have
  to do today" / any to-do concept.
- **Easy to confuse:**
  - "What's on this week" / "what meetings this week" → **calendar** (a schedule).
  - "What do I have to do today" / "today's to-dos" → **reminders** (things to do).
  - "Meeting at 3 tomorrow" → **calendar** (a meeting, an interval).
  - "Remind me to be at the 3pm meeting" → **reminders** (the user said "remind" = a to-do not to
    forget; do **not** also create a calendar event).
- **Command map** (same verbs, different prefix — don't cross them):

  | action | calendar | reminders |
  |---|---|---|
  | list containers | `agendactl calendar calendars` | `agendactl reminders lists` |
  | list items | `agendactl calendar list-events` | `agendactl reminders list` |
  | create | `agendactl calendar create-event` | `agendactl reminders create` |
  | update | `agendactl calendar update-event <id>` | `agendactl reminders update <id>` |
  | complete | (none — events have no "complete"; use `delete-event`) | `agendactl reminders complete <id>` |
  | delete | `agendactl calendar delete-event <id>` | `agendactl reminders delete <id>` |

## Calendar commands

| command | purpose |
|---|---|
| `agendactl calendar calendars` | list all calendars: name + id + writable. **Run before any write.** |
| `agendactl calendar list-events [--calendar <name>] [--from <iso>] [--to <iso>] [--limit <n>]` | list events (default next 30 days), returns `{…meta, items:[...]}` |
| `agendactl calendar create-event --calendar <name> --summary <title> --start <iso> --end <iso> [--location <text>] [--notes <text>] [--all-day]` | create an event, returns one with id |
| `agendactl calendar update-event <id> [--summary] [--start] [--end] [--location] [--notes]` | update (fields not given stay unchanged) |
| `agendactl calendar delete-event <id>` | delete an event |

`<id>` comes from `list-events` / `create-event`. **`--end` must be later than `--start`** (else
exit 1); when changing only one end, keep the order valid.

## Reminders commands

| command | purpose |
|---|---|
| `agendactl reminders lists` | list all lists: name + id + writable. **Run before any write.** |
| `agendactl reminders list [--list <name>] [--status incomplete\|completed\|all] [--due today\|<iso>] [--limit <n>]` | list reminders (default incomplete), returns `{…meta, items:[...]}` |
| `agendactl reminders create --list <name> --name <text> [--notes <text>] [--due <iso>] [--priority 0-9]` | create a reminder, returns one with id |
| `agendactl reminders update <id> [--name] [--notes] [--due] [--priority] [--complete]` | update (fields not given stay unchanged) |
| `agendactl reminders complete <id>` | mark complete |
| `agendactl reminders delete <id>` | delete |

Priority: `0`=none, `1–4`=high, `5`=medium, `6–9`=low (Apple's convention). `--status` defaults to
`incomplete`.

## Dates

- Input ISO 8601: `2026-06-29T09:00:00` (**no tz suffix = local time**); `2026-06-29` is also
  accepted. Output is UTC ISO (with `Z`).
- For relative dates ("today / tomorrow / the day after"), first read `._iso` from any response for
  "today", then do calendar arithmetic with macOS BSD `date` — `date -j -f "%Y-%m-%d" -v+1d "$ISO"
  +%Y-%m-%d` for "tomorrow" (note: BSD `-j -f -v`, not GNU `date -d`). `agendactl` itself accepts only
  full ISO 8601, never expressions like "tomorrow".

Example — "review tomorrow 3–4pm":
```bash
RESP=$(agendactl calendar calendars)                                   # real calendar name (+ _iso)
ISO=$(echo "$RESP" | jq -r ._iso)
CAL=$(echo "$RESP" | jq -r '.items[] | select(.writable) | .name' | head -1)
TOMORROW=$(date -j -f "%Y-%m-%d" -v+1d "$ISO" +%Y-%m-%d)
agendactl calendar create-event --calendar "$CAL" --summary "Review" \
  --start "${TOMORROW}T15:00:00" --end "${TOMORROW}T16:00:00"
```

## Standard workflow (required for writes)

1. **List containers first** (`calendars` / `lists`) to get real names — don't guess ("Personal"
   vs "个人", duplicate "Holidays" calendars write to the wrong place).
2. Call `create` / `update` / `complete` / `delete`.
3. **Compound filtering** (e.g. "events over 1 hour this week", "today's high-priority to-dos"):
   coarse-filter with `--from`/`--to`/`--list`/`--status`/`--due`, then refine in context yourself —
   the CLI does not do complex queries.
4. After writing, re-read with `list` / `list-events` to confirm.
5. **Confirm with the user before bulk deletes**, then delete one by one.

## Exit codes (judge by these, don't guess)

| code | meaning | what to do |
|---|---|---|
| 0 | success | read the JSON on stdout |
| 1 | usage/arg error | read stderr, fix the arguments |
| 2 | name/id not found | pick from stderr's `available:`; or run `calendars`/`lists` first |
| 3 | not authorized | have the user grant Full Access in System Settings → Privacy & Security → Calendars / Reminders |
| 4 | runtime error | read the reason on stderr |

On failure, stderr's first line is `agendactl: <reason>`.

## Not covered (say "not supported yet", don't invent)

- Calendar: attendees/invites, room booking, shared-calendar permissions, recurrence-rule editing.
- Reminders: subtasks, attachments, structured URL/flag read-write.
