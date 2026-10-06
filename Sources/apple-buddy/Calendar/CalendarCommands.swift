import ArgumentParser
import Foundation

struct CalendarGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Create, edit and organize Apple Calendar events, including connected accounts",
        subcommands: [CalendarAccess.self, Calendars.self, MakeCalendar.self, RenameCalendar.self, RemoveCalendar.self, Events.self, ShowEvent.self, AddEvent.self, EditEvent.self, RemoveEvents.self, MoveEvents.self]
    )
}

func eventRows(_ items: [EventItem], calendars: [EventCalendar]) -> String {
    items.map { item in
        let calendar = calendars.first { $0.id == item.calendarID }?.title ?? ""
        return [item.id, DateText.stamp(item.start, hasTime: !item.allDay), DateText.stamp(item.end, hasTime: !item.allDay), calendar, item.title].joined(separator: "\t")
    }.joined(separator: "\n")
}

func eventText(_ item: EventItem, calendars: [EventCalendar]) -> String {
    var lines = [item.id, "Title: \(item.title)", "Calendar: \(calendars.first { $0.id == item.calendarID }?.title ?? item.calendarID)"]
    lines.append("Start: " + DateText.stamp(item.start, hasTime: !item.allDay))
    lines.append("End: " + DateText.stamp(item.end, hasTime: !item.allDay))
    if item.allDay { lines.append("All day: true") }
    if let occurrence = item.occurrence { lines.append("Occurrence: " + DateText.stamp(occurrence)) }
    if let location = item.location, !location.isEmpty { lines.append("Location: \(location)") }
    if let url = item.url { lines.append("URL: \(url)") }
    if !item.alarms.isEmpty { lines.append("Alarms: " + item.alarms.map { "\($0) min before" }.joined(separator: ", ")) }
    if let recurrence = item.recurrence { lines.append("Repeats: " + recurrenceText(recurrence)) }
    if item.status != "none" { lines.append("Status: \(item.status)") }
    if let organizer = item.organizer { lines.append("Organizer: \(organizer)") }
    if !item.attendees.isEmpty { lines.append("Attendees: " + item.attendees.map { "\($0.name ?? $0.email ?? "") (\($0.status))" }.joined(separator: ", ")) }
    if let notes = item.notes, !notes.isEmpty { lines.append(""); lines.append(notes) }
    return lines.joined(separator: "\n")
}

struct CalendarAccess: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "access", abstract: "Request or show Calendar access", discussion: """
        Shows the access status. Without full access, asks macOS for it: a system dialog names the terminal application.
        Access belongs to that application. Allow it once in the dialog or in System Settings, Privacy and Security, Calendars.

        EXAMPLE
          abdy calendar access
        """)

    func run() throws {
        let store = openEventStore()
        var status = store.accessStatus(.event)
        if status != "fullAccess" { _ = try store.requestAccess(.event); status = store.accessStatus(.event) }
        try output.write(["status": status], text: status)
    }
}

struct Calendars: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "calendars", abstract: "List calendars of every account, subscription and delegate", discussion: """
        Prints 1 line per calendar: uuid, source, type, name and RO for read-only calendars, tab separated.
        With --json includes id, title, source, sourceID, type (local, calDAV, exchange, subscription, birthday), color, readOnly and isDefault.
        Read-only calendars such as subscriptions and holidays are listed but refuse new events.

        EXAMPLE
          abdy calendar calendars --json
        """)

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .event)
        let calendars = try store.calendars(.event)
        try output.write(try eventJSON(calendars), text: calendars.map { [$0.id, $0.source, $0.type, $0.title, $0.readOnly ? "RO" : ""].joined(separator: "\t") }.joined(separator: "\n"))
        output.summary("\(calendars.count) calendars")
    }
}

struct MakeCalendar: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "mkcal", abstract: "Create a calendar", discussion: "Creates the calendar in the default account, or in --source. Prints the calendar UUID. Example: abdy calendar mkcal Projects --source iCloud")
    @Argument(help: "Name of the new calendar") var name: String
    @Option(help: ArgumentHelp("Account, by \(EventHelp.source)")) var source: String?

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .event)
        let created = try store.createCalendar(name, kind: .event, sourceID: try source.map { try resolveSource(store, $0).id })
        try output.writeAction("mkcal", try eventJSON(created), notesSync: false)
    }
}

struct RenameCalendar: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "renamecal", abstract: "Rename a calendar", discussion: "Example: abdy calendar renamecal Projects --name Clients")
    @Argument(help: ArgumentHelp("Calendar, by \(EventHelp.calendar)")) var calendar: String
    @Option(name: .customLong("name"), help: "New calendar name") var newName: String

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .event)
        let target = try resolveCalendar(store, kind: .event, calendar)
        guard !target.readOnly else { throw NotesError(description: "Calendar \(target.title) is read-only and cannot be renamed") }
        try output.writeAction("renamecal", try eventJSON(try store.renameCalendar(target.id, to: newName)), notesSync: false)
    }
}

struct RemoveCalendar: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "rmcal", abstract: "Delete a calendar with its events", discussion: "Deletes the calendar and every event in it. Example: abdy calendar rmcal Clients")
    @Argument(help: ArgumentHelp("Calendar, by \(EventHelp.calendar)")) var calendar: String

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .event)
        let target = try resolveCalendar(store, kind: .event, calendar)
        guard !target.readOnly else { throw NotesError(description: "Calendar \(target.title) is read-only and cannot be removed") }
        try store.removeCalendar(target.id)
        var data = try eventJSON(target) as? [String: Any] ?? [:]
        data["deleted"] = true
        try output.writeAction("rmcal", data, notesSync: false)
    }
}

struct Events: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "events", abstract: "List events in a date range", discussion: """
        Prints event UUIDs, 1 per line, sorted by start. Without --from and --to lists today.
        Repeating events appear once per occurrence, JSON carries occurrence for edit and rm --occurrence.
        --long prints uuid, start, end, calendar and title, tab separated. --search keeps events whose title, location or notes contain the text.

        EXAMPLES
          abdy calendar events --from 2026-10-06 --to 2026-10-13 --long
          abdy calendar events --calendar Work --search standup --json
        """)
    @Option(help: ArgumentHelp("Range start, \(DateArgument.help)")) var from: DateArgument?
    @Option(help: ArgumentHelp("Range end, exclusive, \(DateArgument.help)")) var to: DateArgument?
    @Option(help: ArgumentHelp("Only these calendars, repeatable, by \(EventHelp.calendar)")) var calendar: [String] = []
    @Option(help: "Only events whose title, location or notes contain this text") var search: String?
    @OptionGroup var paging: ListPaging

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .event)
        let calendars = try store.calendars(.event)
        let start = from?.date ?? Calendar.current.startOfDay(for: Date())
        let end = to?.date ?? Calendar.current.date(byAdding: .day, value: 1, to: start)!
        guard end > start else { throw ValidationError("--to must be after --from") }
        let ids = try calendar.map { try resolveCalendar(store, kind: .event, $0).id }
        var items = try store.events(from: start, to: end, calendarIDs: ids.isEmpty ? nil : ids)
        if let search {
            items = items.filter { $0.title.localizedCaseInsensitiveContains(search) || ($0.location?.localizedCaseInsensitiveContains(search) ?? false) || ($0.notes?.localizedCaseInsensitiveContains(search) ?? false) }
        }
        let page = try paging.page(items)
        try output.write(try eventJSON(page), text: paging.long ? eventRows(page, calendars: calendars) : page.map(\.id).joined(separator: "\n"))
        output.summary(paging.summary(page.count, of: items.count, "events"))
    }
}

struct ShowEvent: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print an event", discussion: "Prints the event, or 1 occurrence of a repeating event with --occurrence. Attendees are read only. Example: abdy calendar show <id>")
    @Argument(help: ArgumentHelp(EventHelp.event)) var id: String
    @Option(help: ArgumentHelp("Occurrence start of a repeating event, from events --json")) var occurrence: DateArgument?

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .event)
        let item = try resolveEvents(store, [id], occurrence: occurrence?.date)[0]
        try output.write(try eventJSON(item), text: eventText(item, calendars: try store.calendars(.event)))
    }
}

struct EventFields: ParsableArguments {
    @Option(help: ArgumentHelp("Start, \(DateArgument.help)")) var start: DateArgument?
    @Option(help: ArgumentHelp("End, for --all-day the last day included, \(DateArgument.help)")) var end: DateArgument?
    @Option(help: "Length in minutes instead of --end") var duration: Int?
    @Flag(help: "Whole-day event") var allDay = false
    @Option(help: "Location text") var location: String?
    @Option(help: "Notes text") var notes: String?
    @Option(help: "Web address") var url: String?
    @Option(help: "Alarm this many minutes before the start, repeatable") var alarm: [Int] = []
    @Option(name: .customLong("repeat"), help: "Repeat daily, weekly, monthly or yearly") var repeats: Recurrence.Frequency?
    @Option(help: "Repeat every N periods") var interval: Int = 1
    @Option(help: ArgumentHelp("Last repeat date, \(DateArgument.help)")) var until: DateArgument?
    @Option(help: "Number of repeats") var count: Int?

    func validate() throws {
        if end != nil && duration != nil { throw ValidationError("choose either --end or --duration") }
        if let duration, duration <= 0 { throw ValidationError("--duration must be positive") }
        guard interval >= 1 else { throw ValidationError("--interval must be positive") }
        if (until != nil || count != nil) && repeats == nil { throw ValidationError("--until and --count need --repeat") }
        if until != nil && count != nil { throw ValidationError("choose either --until or --count") }
    }

    func recurrence() -> Recurrence? {
        repeats.map { Recurrence(frequency: $0, interval: interval, until: until?.date, count: count) }
    }

    func range(start: Date, allDay: Bool, currentEnd: Date?) throws -> (Date, Date) {
        var finish = end?.date ?? duration.map { start.addingTimeInterval(TimeInterval($0 * 60)) } ?? currentEnd
        if allDay {
            let day = Calendar.current.startOfDay(for: start)
            let last = max(Calendar.current.startOfDay(for: finish ?? day), day)
            return (day, Calendar.current.date(byAdding: .day, value: 1, to: last)!.addingTimeInterval(-1))
        }
        if finish == nil { finish = start.addingTimeInterval(3600) }
        guard finish! > start else { throw ValidationError("--end must be after --start") }
        return (start, finish!)
    }
}

struct AddEvent: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Create an event", discussion: """
        Creates the event in --calendar, or in the default calendar. Without --end or --duration the event lasts 1 hour.
        --all-day uses whole days from --start to --end, both included. Prints the event UUID.

        EXAMPLES
          abdy calendar add "Dentist" --calendar Personal --start 2026-10-09T14:00 --duration 45 --alarm 60
          abdy calendar add "Standup" --calendar Work --start 2026-10-06T09:30 --end 2026-10-06T09:45 --repeat weekly --until 2026-12-31
          abdy calendar add "Holiday" --start 2026-12-24 --end 2026-12-26 --all-day
        """)
    @Argument(help: "Event title") var title: String
    @Option(help: ArgumentHelp("Calendar, by \(EventHelp.calendar)")) var calendar: String?
    @OptionGroup var fields: EventFields

    func run() throws {
        guard let start = fields.start else { throw ValidationError("--start is required") }
        let store = openEventStore()
        try requireAccess(store, .event)
        let target: EventCalendar
        if let calendar { target = try resolveCalendar(store, kind: .event, calendar) } else {
            guard let fallback = try store.calendars(.event).first(where: \.isDefault) else { throw NotesError(description: "No default calendar, pass --calendar") }
            target = fallback
        }
        guard !target.readOnly else { throw NotesError(description: "Calendar \(target.title) is read-only and cannot hold new events") }
        let allDay = fields.allDay || (!start.hasTime && fields.end?.hasTime != true && fields.duration == nil)
        let (begin, finish) = try fields.range(start: start.date, allDay: allDay, currentEnd: nil)
        let item = EventItem(id: "", title: title, calendarID: target.id, calendar: target.title, start: begin, end: finish, allDay: allDay, location: fields.location, notes: fields.notes, url: fields.url,
                             alarms: fields.alarm, recurrence: fields.recurrence(), occurrence: nil, isDetached: false, status: "none", organizer: nil, attendees: [], created: nil, modified: nil)
        try output.writeAction("calendar add", try eventJSON(try store.saveEvents([item], span: .this)[0]), notesSync: false)
    }
}

struct EditEvent: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Change an event", discussion: """
        Changes only the given fields. A repeating event needs --occurrence from events --json and --span this or future.
        --clear-alarms removes alarms, --clear-repeat stops the repeat rule.

        EXAMPLES
          abdy calendar edit <id> --title "Dentist, moved" --start 2026-10-10T15:00 --duration 45
          abdy calendar edit <id> --occurrence 2026-10-13T09:30:00+11:00 --span future --start 2026-10-13T10:00 --duration 15
        """)
    @Argument(help: ArgumentHelp(EventHelp.event)) var id: String
    @Option(help: "New title") var title: String?
    @Option(help: ArgumentHelp("Move to this calendar, by \(EventHelp.calendar)")) var calendar: String?
    @Option(help: ArgumentHelp("Occurrence start of a repeating event, from events --json")) var occurrence: DateArgument?
    @Option(help: "For a repeating event: this occurrence or all future ones") var span: EditSpan?
    @OptionGroup var fields: EventFields
    @Flag(help: "Remove every alarm") var clearAlarms = false
    @Flag(help: "Stop the repeat rule") var clearRepeat = false

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .event)
        var item = try resolveEvents(store, [id], occurrence: occurrence?.date)[0]
        if item.recurrence != nil || item.occurrence != nil {
            guard occurrence != nil else { throw ValidationError("this event repeats, pass --occurrence from events --json") }
            guard span != nil else { throw ValidationError("this event repeats, pass --span this or --span future") }
        }
        if let title { item.title = title }
        if let calendar {
            let target = try resolveCalendar(store, kind: .event, calendar)
            guard !target.readOnly else { throw NotesError(description: "Calendar \(target.title) is read-only and cannot be the target") }
            item.calendarID = target.id
        }
        if fields.allDay { item.allDay = true }
        if let start = fields.start, !start.hasTime, fields.end?.hasTime != true, fields.duration == nil { item.allDay = true }
        let start = fields.start?.date ?? item.start
        let (begin, finish) = try fields.range(start: start, allDay: item.allDay, currentEnd: start.addingTimeInterval(item.end.timeIntervalSince(item.start)))
        item.start = begin
        item.end = finish
        if let location = fields.location { item.location = location }
        if let notes = fields.notes { item.notes = notes }
        if let url = fields.url { item.url = url }
        if clearAlarms { item.alarms = [] }
        if !fields.alarm.isEmpty { item.alarms = fields.alarm }
        if clearRepeat { item.recurrence = nil }
        if let recurrence = fields.recurrence() { item.recurrence = recurrence }
        try output.writeAction("calendar edit", try eventJSON(try store.saveEvents([item], span: span ?? .this)[0]), notesSync: false)
    }
}

struct RemoveEvents: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete events", discussion: """
        Deletes for good, Calendar has no trash. Takes 1 or more ids, or - for ids from stdin.
        A repeating event needs --occurrence and --span this or future, which apply to every id in the call.

        EXAMPLES
          abdy calendar rm <id>
          abdy calendar rm <id> --occurrence 2026-10-13T09:30:00+11:00 --span this
        """)
    @Argument(help: ArgumentHelp("1 or more events, by \(EventHelp.event), or - for ids from stdin")) var ids: [String]
    @Option(help: ArgumentHelp("Occurrence start of a repeating event, from events --json")) var occurrence: DateArgument?
    @Option(help: "For a repeating event: this occurrence or all future ones") var span: EditSpan?

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .event)
        let items = try resolveEvents(store, try noteReferences(ids), occurrence: occurrence?.date)
        if items.contains(where: { $0.recurrence != nil || $0.occurrence != nil }) {
            guard occurrence != nil, span != nil else { throw ValidationError("a repeating event needs --occurrence from events --json and --span this or future") }
        }
        try store.removeEvents(items, span: span ?? .this)
        try output.writeBatch("calendar rm", items: try eventJSON(items), key: "events", summary: "calendar rm: \(items.count) events deleted", notesSync: false)
    }
}

struct MoveEvents: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "mv", abstract: "Move events to another calendar", discussion: "Takes 1 or more ids, or - for ids from stdin. Repeating events move as a whole. Saves once. Example: abdy calendar mv <id> --calendar Work")
    @Argument(help: ArgumentHelp("1 or more events, by \(EventHelp.event), or - for ids from stdin")) var ids: [String]
    @Option(help: ArgumentHelp("Target calendar, by \(EventHelp.calendar)")) var calendar: String

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .event)
        let target = try resolveCalendar(store, kind: .event, calendar)
        guard !target.readOnly else { throw NotesError(description: "Calendar \(target.title) is read-only and cannot be the target") }
        var items = try resolveEvents(store, try noteReferences(ids), occurrence: nil)
        for index in items.indices { items[index].calendarID = target.id }
        let saved = try store.saveEvents(items, span: .future)
        try output.writeBatch("calendar mv", items: try eventJSON(saved), key: "events", summary: "calendar mv: \(saved.count) events to \(target.title)", notesSync: false)
    }
}
