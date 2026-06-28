#!/usr/bin/swift
//
// agendactl — a thin CLI-only shell over Apple's EventKit (Calendar + Reminders).
// Contract: see docs/adr/ADR-0001..0012. Agents only call this CLI; they never
// touch JXA / EventKit internals.
// Exit codes: 0 ok / 1 usage error / 2 not found / 3 not authorized / 4 runtime error.
// Success: stdout = bare JSON. Failure: stderr = "agendactl: <msg>".
// Date input: ISO 8601 (no suffix = local tz). Date output: UTC ISO.
//
import EventKit
import Foundation

let store = EKEventStore()

// ---------- output / errors ----------
// Every response carries a meta layer: the moment the CLI ran (kept distinct
// from the item's own time — due/start/end).
// Array responses are wrapped as {_at, _tz, _iso, _note, items: [...]};
// object responses get these keys merged onto the original fields.
func emit(_ obj: Any) {
    let now = Date()
    let f = ISO8601DateFormatter(); f.timeZone = .current; f.formatOptions = [.withInternetDateTime]
    let at = f.string(from: now)
    let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
    df.timeZone = .current; df.dateFormat = "yyyy-MM-dd"
    let meta: [String: Any] = [
        "_at": at,
        "_tz": TimeZone.current.identifier,
        "_iso": df.string(from: now),
        "_note": "Generated at \(at) — CLI call time, not the item's time (use _iso for 'today')"
    ]
    var out = meta
    if let d = obj as? [String: Any] {
        for (k, v) in d { out[k] = v }
    } else if let arr = obj as? [Any] {
        out["items"] = arr
    } else {
        out["value"] = obj
    }
    let data = try! JSONSerialization.data(withJSONObject: out, options: [])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}
func fail(_ code: Int32, _ msg: String, hint: String? = nil, available: [String]? = nil) -> Never {
    var s = "agendactl: \(msg)\n"
    if let h = hint { s += "hint: \(h)\n" }
    if let a = available { s += "available: \(a.joined(separator: ", "))\n" }
    FileHandle.standardError.write(s.data(using: .utf8)!)
    exit(code)
}

// ---------- dates ----------
let isoUTC: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); return f
}()
func parseDate(_ s: String) -> Date? {
    if let d = ISO8601DateFormatter().date(from: s) { return d }          // has tz suffix
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
    for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
        f.dateFormat = fmt
        if let d = f.date(from: s) { return d }
    }
    return nil
}
func isoStr(_ d: Date?) -> String { d.map { isoUTC.string(from: $0) } ?? "" }

// ---------- argument parsing ----------
let valueFlags: Set<String> = ["--calendar","--list","--from","--to","--limit","--summary",
    "--name","--start","--end","--location","--notes","--description","--body","--due",
    "--priority","--status","--index","--tag"]
func parseFlags(_ a: [String]) -> (pos: [String], fl: [String:String], bo: Set<String>) {
    var pos: [String] = []; var fl: [String:String] = [:]; var bo: Set<String> = []
    var i = 0
    while i < a.count {
        let t = a[i]
        if t.hasPrefix("--") {
            if valueFlags.contains(t) {
                // consume the next token as the value only if it isn't itself a flag;
                // otherwise leave this flag unset so required-field validation catches it
                if i + 1 < a.count, !a[i+1].hasPrefix("--") { fl[t] = a[i+1]; i += 2 }
                else { i += 1 }
            } else { bo.insert(t); i += 1 }
        } else { pos.append(t); i += 1 }
    }
    return (pos, fl, bo)
}
func intFlag(_ fl: [String:String], _ k: String) -> Int? { fl[k].flatMap { Int($0) } }

// ---------- authorization ----------
func authEvents() {
    let sema = DispatchSemaphore(value: 0); var ok = false; var errMsg = ""
    store.requestFullAccessToEvents { g, e in ok = g; if let e = e { errMsg = e.localizedDescription }; sema.signal() }
    sema.wait()
    if !ok { fail(3, "Calendar not authorized (EventKit events)" + (errMsg.isEmpty ? "" : ": \(errMsg)"),
        hint: "System Settings → Privacy & Security → Calendars: grant the terminal Full Access, or re-run to trigger the prompt") }
}
func authReminders() {
    let sema = DispatchSemaphore(value: 0); var ok = false; var errMsg = ""
    store.requestFullAccessToReminders { g, e in ok = g; if let e = e { errMsg = e.localizedDescription }; sema.signal() }
    sema.wait()
    if !ok { fail(3, "Reminders not authorized (EventKit reminders)" + (errMsg.isEmpty ? "" : ": \(errMsg)"),
        hint: "System Settings → Privacy & Security → Reminders: grant the terminal Full Access") }
}

// ---------- container name resolution (ADR-0006: duplicate-name disambiguation) ----------
func resolveCalendar(_ name: String, _ entity: EKEntityType, index: Int?) -> EKCalendar {
    let cals = store.calendars(for: entity)
    let matches = cals.filter { $0.title == name }
    if matches.isEmpty { fail(2, "container not found: \(name)", available: cals.map { $0.title }) }
    if matches.count > 1 {
        if let i = index, i >= 0, i < matches.count { return matches[i] }
        fail(2, "\(matches.count) containers share the name: \(name)",
             hint: "add --index <n> to pick one", available: matches.map { $0.calendarIdentifier })
    }
    return matches[0]
}

// ---------- Reminders: synchronous fetch ----------
func fetchReminders(_ pred: NSPredicate) -> [EKReminder] {
    let sema = DispatchSemaphore(value: 0); var res: [EKReminder] = []
    store.fetchReminders(matching: pred) { arr in res = arr ?? []; sema.signal() }
    sema.wait(); return res
}
func dueISO(_ r: EKReminder) -> String {
    if let dc = r.dueDateComponents, let d = Calendar.current.date(from: dc) { return isoStr(d) }
    return ""
}

// ================= Calendar =================
func cmdCalendars() {
    authEvents()
    emit(store.calendars(for: .event).map {
        ["name": $0.title, "id": $0.calendarIdentifier, "writable": $0.allowsContentModifications] as [String: Any]
    })
}
func cmdListEvents(_ fl: [String:String]) {
    authEvents()
    let cals = fl["--calendar"].map { [resolveCalendar($0, .event, index: intFlag(fl, "--index"))] }
    let from = fl["--from"].flatMap(parseDate) ?? Date()
    let to = fl["--to"].flatMap(parseDate) ?? Calendar.current.date(byAdding: .day, value: 30, to: from)!
    let pred = store.predicateForEvents(withStart: from, end: to, calendars: cals)
    var evs = store.events(matching: pred)
    if let lim = intFlag(fl, "--limit") { evs = Array(evs.prefix(lim)) }
    emit(evs.map {
        ["id": $0.eventIdentifier ?? "", "summary": $0.title ?? "", "calendar": $0.calendar.title,
         "start": isoStr($0.startDate), "end": isoStr($0.endDate),
         "location": $0.location ?? "", "allDay": $0.isAllDay] as [String: Any]
    })
}
func cmdCreateEvent(_ fl: [String:String], _ bo: Set<String>) {
    authEvents()
    guard let calName = fl["--calendar"], let summary = fl["--summary"],
          let startS = fl["--start"], let endS = fl["--end"]
    else { fail(1, "missing required: --calendar --summary --start --end") }
    guard let start = parseDate(startS) else { fail(1, "--start is not valid ISO: \(startS)") }
    guard let end = parseDate(endS) else { fail(1, "--end is not valid ISO: \(endS)") }
    if end <= start { fail(1, "--end must be later than --start") }            // ADR-0006
    let cal = resolveCalendar(calName, .event, index: intFlag(fl, "--index"))
    if !cal.allowsContentModifications { fail(2, "calendar is read-only: \(calName)") }
    let ev = EKEvent(eventStore: store)
    ev.calendar = cal; ev.title = summary; ev.startDate = start; ev.endDate = end
    if let loc = fl["--location"] { ev.location = loc }
    if let n = fl["--notes"] ?? fl["--description"] { ev.notes = n }
    if bo.contains("--all-day") { ev.isAllDay = true }
    do { try store.save(ev, span: .thisEvent, commit: true) }
    catch { fail(4, "save failed: \(error.localizedDescription)") }
    emit(["id": ev.eventIdentifier ?? "", "summary": ev.title ?? "",
          "start": isoStr(ev.startDate), "end": isoStr(ev.endDate)] as [String: Any])
}
func cmdUpdateEvent(_ pos: [String], _ fl: [String:String]) {
    authEvents()
    guard let id = pos.first else { fail(1, "missing <id>") }
    guard let ev = store.event(withIdentifier: id) else { fail(2, "event not found: \(id)") }
    if let s = fl["--summary"] { ev.title = s }
    if let v = fl["--start"] { guard let d = parseDate(v) else { fail(1, "--start invalid") }; ev.startDate = d }
    if let v = fl["--end"] { guard let d = parseDate(v) else { fail(1, "--end invalid") }; ev.endDate = d }
    if ev.endDate <= ev.startDate { fail(1, "--end must be later than --start") }
    if let loc = fl["--location"] { ev.location = loc }
    if let n = fl["--notes"] ?? fl["--description"] { ev.notes = n }
    do { try store.save(ev, span: .thisEvent, commit: true) }
    catch { fail(4, "save failed: \(error.localizedDescription)") }
    emit(["id": ev.eventIdentifier ?? "", "summary": ev.title ?? "",
          "start": isoStr(ev.startDate), "end": isoStr(ev.endDate)] as [String: Any])
}
func cmdDeleteEvent(_ pos: [String]) {
    authEvents()
    guard let id = pos.first else { fail(1, "missing <id>") }
    guard let ev = store.event(withIdentifier: id) else { fail(2, "event not found: \(id)") }
    do { try store.remove(ev, span: .thisEvent, commit: true) }
    catch { fail(4, "delete failed: \(error.localizedDescription)") }
    emit(["deleted": id])
}

// ================= Reminders =================
func cmdReminderLists() {
    authReminders()
    emit(store.calendars(for: .reminder).map {
        ["name": $0.title, "id": $0.calendarIdentifier, "writable": $0.allowsContentModifications] as [String: Any]
    })
}
func cmdReminderList(_ fl: [String:String]) {
    authReminders()
    let cals = fl["--list"].map { [resolveCalendar($0, .reminder, index: intFlag(fl, "--index"))] }
    let status = fl["--status"] ?? "incomplete"
    let pred: NSPredicate
    switch status {
    case "incomplete": pred = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
    case "completed":  pred = store.predicateForCompletedReminders(withCompletionDateStarting: nil, ending: nil, calendars: cals)
    case "all":        pred = store.predicateForReminders(in: cals)
    default:           fail(1, "--status must be incomplete|completed|all: \(status)")
    }
    var rems = fetchReminders(pred)
    let cal = Calendar.current
    if let dueRaw = fl["--due"] {
        if dueRaw == "today" {
            let t0 = cal.startOfDay(for: Date()); let t1 = cal.date(byAdding: .day, value: 1, to: t0)!
            rems = rems.filter { if let dc = $0.dueDateComponents, let d = cal.date(from: dc) { return d >= t0 && d < t1 }; return false }
        } else {
            guard let dd = parseDate(dueRaw) else { fail(1, "--due must be 'today' or ISO 8601: \(dueRaw)") }
            rems = rems.filter { if let dc = $0.dueDateComponents, let d = cal.date(from: dc) { return d <= dd }; return false }
        }
    }
    if let lim = intFlag(fl, "--limit") { rems = Array(rems.prefix(lim)) }
    emit(rems.map {
        ["id": $0.calendarItemIdentifier, "name": $0.title ?? "", "list": $0.calendar.title,
         "completed": $0.isCompleted, "priority": $0.priority, "due": dueISO($0)] as [String: Any]
    })
}
func setDue(_ r: EKReminder, _ d: Date) {
    r.dueDateComponents = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute,.second], from: d)
}
func reminderByID(_ id: String) -> EKReminder {
    guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { fail(2, "reminder not found: \(id)") }
    return r
}
func cmdReminderCreate(_ fl: [String:String]) {
    authReminders()
    guard let listName = fl["--list"], let name = fl["--name"] else { fail(1, "missing required: --list --name") }
    let cal = resolveCalendar(listName, .reminder, index: intFlag(fl, "--index"))
    if !cal.allowsContentModifications { fail(2, "reminder list is read-only: \(listName)") }
    let r = EKReminder(eventStore: store)
    r.calendar = cal; r.title = name
    if let n = fl["--notes"] ?? fl["--body"] { r.notes = n }
    if let dueS = fl["--due"] { guard let d = parseDate(dueS) else { fail(1, "--due is not valid ISO: \(dueS)") }; setDue(r, d) }
    if let p = intFlag(fl, "--priority") { guard (0...9).contains(p) else { fail(1, "--priority must be 0-9") }; r.priority = p }
    do { try store.save(r, commit: true) } catch { fail(4, "save failed: \(error.localizedDescription)") }
    emit(["id": r.calendarItemIdentifier, "name": r.title ?? "", "list": cal.title, "due": dueISO(r)] as [String: Any])
}
func cmdReminderUpdate(_ pos: [String], _ fl: [String:String], _ bo: Set<String>) {
    authReminders()
    guard let id = pos.first else { fail(1, "missing <id>") }
    let r = reminderByID(id)
    if let s = fl["--name"] { r.title = s }
    if let n = fl["--notes"] ?? fl["--body"] { r.notes = n }
    if let dueS = fl["--due"] { guard let d = parseDate(dueS) else { fail(1, "--due is not valid ISO: \(dueS)") }; setDue(r, d) }
    if let p = intFlag(fl, "--priority") { guard (0...9).contains(p) else { fail(1, "--priority must be 0-9") }; r.priority = p }
    if bo.contains("--complete") { r.isCompleted = true }
    do { try store.save(r, commit: true) } catch { fail(4, "save failed: \(error.localizedDescription)") }
    emit(["id": r.calendarItemIdentifier, "name": r.title ?? "", "completed": r.isCompleted, "due": dueISO(r)] as [String: Any])
}
func cmdReminderComplete(_ pos: [String]) {
    authReminders()
    guard let id = pos.first else { fail(1, "missing <id>") }
    let r = reminderByID(id); r.isCompleted = true
    do { try store.save(r, commit: true) } catch { fail(4, "save failed: \(error.localizedDescription)") }
    emit(["id": r.calendarItemIdentifier, "completed": true] as [String: Any])
}
func cmdReminderDelete(_ pos: [String]) {
    authReminders()
    guard let id = pos.first else { fail(1, "missing <id>") }
    let r = reminderByID(id)
    do { try store.remove(r, commit: true) } catch { fail(4, "delete failed: \(error.localizedDescription)") }
    emit(["deleted": id])
}

// ================= help =================
let HELP_TOP = """
agendactl — read & write macOS Calendar and Reminders (EventKit)

Usage:
  agendactl <app> <cmd> [flags]
  agendactl <app> --help

Apps:
  calendar    calendar events (list / create / update / delete)
  reminders   reminders / to-dos (list / create / update / delete / complete)

Responses:
  Every response carries _at (CLI run time) / _tz / _iso / _note at the top level.
  List responses are wrapped as {meta, items: [...]}; write responses merge meta onto the fields.
  When building relative dates ("today at 3pm"), read the date from ._iso.

Conventions:
  Success → exit 0, stdout is bare JSON. Failure → stderr first line `agendactl: <reason>`.
  Exit codes: 0 ok / 1 usage error / 2 not found / 3 not authorized / 4 runtime error
  Dates: input ISO 8601 (no tz suffix = local tz), output UTC ISO

Per-app command detail: agendactl calendar --help / agendactl reminders --help
"""
let HELP_CALENDAR = """
agendactl calendar — calendar events (EventKit)

  calendars
      list all calendars: name + id + writable
  list-events [--calendar <name>] [--from <iso>] [--to <iso>] [--limit <n>]
      list events (default: next 30 days), returns {…meta, items:[...]}
  create-event --calendar <name> --summary <title> --start <iso> --end <iso>
               [--location <text>] [--notes <text>] [--all-day]
      create an event, returns one with id; --end must be later than --start
  update-event <id> [--summary] [--start] [--end] [--location] [--notes]
      update an event (fields not given stay unchanged)
  delete-event <id>
      delete an event

Duplicate calendar names → exit 2 + candidate list; disambiguate with --index <n>.
"""
let HELP_REMINDERS = """
agendactl reminders — reminders / to-dos (EventKit)

  lists
      list all lists: name + id + writable
  list [--list <name>] [--status incomplete|completed|all] [--due today|<iso>] [--limit <n>]
      list reminders (default: incomplete), returns {…meta, items:[...]}
  create --list <name> --name <text> [--notes <text>] [--due <iso>] [--priority 0-9]
      create a reminder, returns one with id; priority 0=none 1-4=high 5=medium 6-9=low
  update <id> [--name] [--notes] [--due] [--priority] [--complete]
      update a reminder (fields not given stay unchanged)
  complete <id>
      mark complete
  delete <id>
      delete
"""
func printHelp(_ s: String) -> Never { print(s); exit(0) }

// ================= dispatch =================
let argv = Array(CommandLine.arguments.dropFirst())
let wantsHelp = argv.contains("--help") || argv.contains("-h")
guard let app = argv.first, !["--help", "-h"].contains(app) else { printHelp(HELP_TOP) }
let rest = Array(argv.dropFirst())

// agendactl <app> --help  or  agendactl <app> (no subcommand) → that app's help
if app == "calendar",  rest.first == nil || wantsHelp { printHelp(HELP_CALENDAR) }
if app == "reminders", rest.first == nil || wantsHelp { printHelp(HELP_REMINDERS) }

guard let cmd = rest.first else { fail(1, "missing subcommand; see `agendactl \(app) --help`") }
let (pos, fl, bo) = parseFlags(Array(rest.dropFirst()))

switch (app, cmd) {
case ("calendar", "calendars"):    cmdCalendars()
case ("calendar", "list-events"):  cmdListEvents(fl)
case ("calendar", "create-event"): cmdCreateEvent(fl, bo)
case ("calendar", "update-event"): cmdUpdateEvent(pos, fl)
case ("calendar", "delete-event"): cmdDeleteEvent(pos)
case ("reminders", "lists"):       cmdReminderLists()
case ("reminders", "list"):        cmdReminderList(fl)
case ("reminders", "create"):      cmdReminderCreate(fl)
case ("reminders", "update"):      cmdReminderUpdate(pos, fl, bo)
case ("reminders", "complete"):    cmdReminderComplete(pos)
case ("reminders", "delete"):      cmdReminderDelete(pos)
default: fail(1, "unknown command: \(app) \(cmd); see `agendactl --help`")
}
