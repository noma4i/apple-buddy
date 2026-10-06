import ArgumentParser
import Foundation

struct Reminders: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create, edit and organize Apple Reminders",
        subcommands: [RemindersAccess.self, ReminderLists.self, MakeList.self, RenameList.self, RemoveList.self, ListReminders.self, ShowReminder.self, SearchReminders.self,
                      AddReminder.self, EditReminder.self, CompleteReminders.self, ReopenReminders.self, RemoveReminders.self, MoveReminders.self]
    )
}

func reminderRows(_ items: [ReminderItem], lists: [EventCalendar]) -> String {
    items.map { item in
        let due = item.due.map { DateText.stamp($0, hasTime: item.dueHasTime) } ?? ""
        let list = lists.first { $0.id == item.listID }?.title ?? ""
        return [item.id, due, list, item.title].joined(separator: "\t")
    }.joined(separator: "\n")
}

func reminderText(_ item: ReminderItem, lists: [EventCalendar]) -> String {
    var lines = [item.id, "Title: \(item.title)", "List: \(lists.first { $0.id == item.listID }?.title ?? item.listID)"]
    if let due = item.due { lines.append("Due: " + DateText.stamp(due, hasTime: item.dueHasTime)) }
    lines.append("Priority: \(item.priority)")
    lines.append("Completed: \(item.completed)" + (item.completionDate.map { " at " + DateText.stamp($0) } ?? ""))
    if let url = item.url { lines.append("URL: \(url)") }
    if !item.alarms.isEmpty { lines.append("Alarms: " + item.alarms.map { "\($0) min before" }.joined(separator: ", ")) }
    if let recurrence = item.recurrence { lines.append("Repeats: " + recurrenceText(recurrence)) }
    if let notes = item.notes, !notes.isEmpty { lines.append(""); lines.append(notes) }
    return lines.joined(separator: "\n")
}

func recurrenceText(_ recurrence: Recurrence) -> String {
    var text = recurrence.interval == 1 ? recurrence.frequency.rawValue : "every \(recurrence.interval) " + recurrence.frequency.rawValue.replacingOccurrences(of: "ly", with: "")
    if let until = recurrence.until { text += " until " + DateText.stamp(until, hasTime: false) }
    if let count = recurrence.count { text += " for \(count) times" }
    return text
}

struct ListPaging: ParsableArguments {
    @Flag(help: "Print 1 line per item: uuid, date, list or calendar and title, tab separated") var long = false
    @Option(help: "Maximum number of items") var limit: Int?
    @Option(help: "Skip this many items") var offset = 0

    func page<T>(_ items: [T]) throws -> [T] {
        if let limit, limit <= 0 { throw ValidationError("--limit must be positive") }
        guard offset >= 0 else { throw ValidationError("--offset must be nonnegative") }
        let start = min(offset, items.count)
        return Array(items[start..<min(start + (limit ?? items.count), items.count)])
    }

    func summary(_ shown: Int, of total: Int, _ noun: String) -> String {
        limit == nil && offset == 0 ? "\(shown) \(noun)" : "\(shown) of \(total) \(noun)"
    }
}

struct RemindersAccess: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "access", abstract: "Request or show Reminders access", discussion: """
        Shows the access status. Without full access, asks macOS for it: a system dialog names the terminal application.
        Access belongs to that application. Allow it once in the dialog or in System Settings, Privacy and Security, Reminders.

        EXAMPLE
          abdy reminders access
        """)

    func run() throws {
        let store = openEventStore()
        var status = store.accessStatus(.reminder)
        if status != "fullAccess" { _ = try store.requestAccess(.reminder); status = store.accessStatus(.reminder) }
        try output.write(["status": status], text: status)
    }
}

struct ReminderLists: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "lists", abstract: "List reminder lists of every account", discussion: """
        Prints 1 line per list: uuid, source, name and open reminder count, tab separated.
        With --json includes id, title, source, sourceID, type, color, readOnly, isDefault and count.

        EXAMPLE
          abdy reminders lists --json
        """)

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let lists = try store.calendars(.reminder)
        let open = try store.reminders(listIDs: nil).filter { !$0.completed }
        let counted = try lists.map { list -> [String: Any] in
            var value = try eventJSON(list) as? [String: Any] ?? [:]
            value["count"] = open.filter { $0.listID == list.id }.count
            return value
        }
        try output.write(counted, text: lists.map { list in "\(list.id)\t\(list.source)\t\(list.title)\t\(open.filter { $0.listID == list.id }.count)" }.joined(separator: "\n"))
        output.summary("\(lists.count) lists")
    }
}

struct MakeList: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "mklist", abstract: "Create a reminder list", discussion: """
        Creates the list in the default account, or in --source. Prints the list UUID.

        EXAMPLE
          abdy reminders mklist Groceries --source iCloud
        """)
    @Argument(help: "Name of the new list") var name: String
    @Option(help: ArgumentHelp("Account, by \(EventHelp.source)")) var source: String?

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let created = try store.createCalendar(name, kind: .reminder, sourceID: try source.map { try resolveSource(store, $0).id })
        try output.writeAction("mklist", try eventJSON(created), notesSync: false)
    }
}

struct RenameList: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "renamelist", abstract: "Rename a reminder list", discussion: "Example: abdy reminders renamelist Groceries --name Shopping")
    @Argument(help: ArgumentHelp("List, by \(EventHelp.list)")) var list: String
    @Option(name: .customLong("name"), help: "New list name") var newName: String

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let target = try resolveCalendar(store, kind: .reminder, list)
        guard !target.readOnly else { throw NotesError(description: "List \(target.title) is read-only and cannot be renamed") }
        try output.writeAction("renamelist", try eventJSON(try store.renameCalendar(target.id, to: newName)), notesSync: false)
    }
}

struct RemoveList: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "rmlist", abstract: "Delete a reminder list with its reminders", discussion: "Deletes the list and every reminder in it. Example: abdy reminders rmlist Shopping")
    @Argument(help: ArgumentHelp("List, by \(EventHelp.list)")) var list: String

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let target = try resolveCalendar(store, kind: .reminder, list)
        guard !target.readOnly else { throw NotesError(description: "List \(target.title) is read-only and cannot be removed") }
        try store.removeCalendar(target.id)
        var data = try eventJSON(target) as? [String: Any] ?? [:]
        data["deleted"] = true
        try output.writeAction("rmlist", data, notesSync: false)
    }
}

struct ListReminders: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "ls", abstract: "List reminders", discussion: """
        Prints open reminders of every list as UUIDs, 1 per line, sorted by due date then title. Items without a due date come last.
        --completed lists only completed reminders, --all lists both.
        --long prints uuid, due date, list and title, tab separated. With --json prints the full reminder objects.

        EXAMPLES
          abdy reminders ls --list Groceries --long
          abdy reminders ls --due-before 2026-10-08 --json
        """)
    @Option(help: ArgumentHelp("Only this list, by \(EventHelp.list)")) var list: String?
    @Flag(help: "Only completed reminders") var completed = false
    @Flag(help: "Open and completed reminders") var all = false
    @Option(help: ArgumentHelp("Only reminders due before this date, \(DateArgument.help)")) var dueBefore: DateArgument?
    @Option(help: ArgumentHelp("Only reminders due after this date, \(DateArgument.help)")) var dueAfter: DateArgument?
    @OptionGroup var paging: ListPaging

    func run() throws {
        guard !(completed && all) else { throw ValidationError("choose either --completed or --all") }
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let lists = try store.calendars(.reminder)
        let listIDs = try list.map { [try resolveCalendar(store, kind: .reminder, $0).id] }
        var items = try store.reminders(listIDs: listIDs)
        if !all { items = items.filter { $0.completed == completed } }
        if let dueBefore { items = items.filter { $0.due.map { $0 < dueBefore.date } ?? false } }
        if let dueAfter { items = items.filter { $0.due.map { $0 > dueAfter.date } ?? false } }
        items.sort { a, b in
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: return x < y
            case (nil, .some): return false
            case (.some, nil): return true
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
        let page = try paging.page(items)
        try output.write(try eventJSON(page), text: paging.long ? reminderRows(page, lists: lists) : page.map(\.id).joined(separator: "\n"))
        output.summary(paging.summary(page.count, of: items.count, "reminders"))
    }
}

struct ShowReminder: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print a reminder", discussion: "Prints title, list, due date, priority, completion, URL, alarms, repeat rule and notes. Example: abdy reminders show <id>")
    @Argument(help: ArgumentHelp(EventHelp.reminder)) var id: String

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let item = try resolveReminders(store, [id])[0]
        try output.write(try eventJSON(item), text: reminderText(item, lists: try store.calendars(.reminder)))
    }
}

struct SearchReminders: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "search", abstract: "Find reminders by text in the title or notes", discussion: """
        Case-insensitive substring match. Searches open reminders unless --all is set.

        EXAMPLE
          abdy reminders search milk --long
        """)
    @Argument(help: "Text to find") var query: String
    @Option(help: ArgumentHelp("Only this list, by \(EventHelp.list)")) var list: String?
    @Flag(help: "Search completed reminders too") var all = false
    @OptionGroup var paging: ListPaging

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let lists = try store.calendars(.reminder)
        let listIDs = try list.map { [try resolveCalendar(store, kind: .reminder, $0).id] }
        let items = try store.reminders(listIDs: listIDs).filter { item in
            (all || !item.completed) && (item.title.localizedCaseInsensitiveContains(query) || (item.notes?.localizedCaseInsensitiveContains(query) ?? false))
        }
        let page = try paging.page(items)
        try output.write(try eventJSON(page), text: paging.long ? reminderRows(page, lists: lists) : page.map(\.id).joined(separator: "\n"))
        output.summary(paging.summary(page.count, of: items.count, "reminders"))
    }
}

struct ReminderFields: ParsableArguments {
    @Option(help: "Notes text") var notes: String?
    @Option(help: ArgumentHelp("Due date, \(DateArgument.help)")) var due: DateArgument?
    @Option(help: "Priority 0 (none), 1 (high), 5 (medium) or 9 (low)") var priority: Int?
    @Option(help: "Web address") var url: String?
    @Option(help: "Alarm this many minutes before the due date, repeatable") var alarm: [Int] = []
    @Option(name: .customLong("repeat"), help: "Repeat daily, weekly, monthly or yearly") var repeats: Recurrence.Frequency?
    @Option(help: "Repeat every N periods") var interval: Int = 1
    @Option(help: ArgumentHelp("Last repeat date, \(DateArgument.help)")) var until: DateArgument?
    @Option(help: "Number of repeats") var count: Int?

    func validate() throws {
        if let priority, !(0...9).contains(priority) { throw ValidationError("--priority must be between 0 and 9") }
        guard interval >= 1 else { throw ValidationError("--interval must be positive") }
        if (until != nil || count != nil) && repeats == nil { throw ValidationError("--until and --count need --repeat") }
        if until != nil && count != nil { throw ValidationError("choose either --until or --count") }
        if repeats != nil && due == nil { throw ValidationError("--repeat needs --due") }
    }

    func recurrence() -> Recurrence? {
        repeats.map { Recurrence(frequency: $0, interval: interval, until: until?.date, count: count) }
    }
}

struct AddReminder: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Create a reminder", discussion: """
        Creates the reminder in --list, or in the default list. Prints its UUID.

        EXAMPLES
          abdy reminders add "Buy milk" --list Groceries --due 2026-10-07T18:00 --alarm 30
          abdy reminders add "Pay rent" --due 2026-10-01 --repeat monthly --priority 1
        """)
    @Argument(help: "Reminder title") var title: String
    @Option(help: ArgumentHelp("List, by \(EventHelp.list)")) var list: String?
    @OptionGroup var fields: ReminderFields

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let target: EventCalendar
        if let list { target = try resolveCalendar(store, kind: .reminder, list) } else {
            guard let fallback = try store.calendars(.reminder).first(where: \.isDefault) else { throw NotesError(description: "No default reminder list, pass --list") }
            target = fallback
        }
        guard !target.readOnly else { throw NotesError(description: "List \(target.title) is read-only and cannot hold new reminders") }
        let item = ReminderItem(id: "", title: title, notes: fields.notes, listID: target.id, list: target.title, due: fields.due?.date, dueHasTime: fields.due?.hasTime ?? false, priority: fields.priority ?? 0,
                                completed: false, completionDate: nil, url: fields.url, alarms: fields.alarm, recurrence: fields.recurrence(), created: nil, modified: nil)
        let saved = try store.saveReminders([item])[0]
        try output.writeAction("reminders add", try eventJSON(saved), notesSync: false)
    }
}

struct EditReminder: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "edit", abstract: "Change a reminder", discussion: """
        Changes only the given fields. --clear-due removes the due date and repeat rule, --clear-alarms removes alarms.

        EXAMPLE
          abdy reminders edit <id> --title "Buy oat milk" --due 2026-10-08T09:00
        """)
    @Argument(help: ArgumentHelp(EventHelp.reminder)) var id: String
    @Option(help: "New title") var title: String?
    @OptionGroup var fields: ReminderFields
    @Flag(help: "Remove the due date and repeat rule") var clearDue = false
    @Flag(help: "Remove every alarm") var clearAlarms = false

    func run() throws {
        guard !(clearDue && fields.due != nil) else { throw ValidationError("choose either --due or --clear-due") }
        let store = openEventStore()
        try requireAccess(store, .reminder)
        var item = try resolveReminders(store, [id])[0]
        if let title { item.title = title }
        if let notes = fields.notes { item.notes = notes }
        if let due = fields.due { item.due = due.date; item.dueHasTime = due.hasTime }
        if clearDue { item.due = nil; item.dueHasTime = false; item.recurrence = nil }
        if let priority = fields.priority { item.priority = priority }
        if let url = fields.url { item.url = url }
        if clearAlarms { item.alarms = [] }
        if !fields.alarm.isEmpty { item.alarms = fields.alarm }
        if let recurrence = fields.recurrence() { item.recurrence = recurrence }
        if fields.repeats != nil && item.due == nil { throw ValidationError("--repeat needs a due date") }
        try output.writeAction("reminders edit", try eventJSON(try store.saveReminders([item])[0]), notesSync: false)
    }
}

func updateReminders(_ output: OutputOptions, action: String, ids: [String], summary: String, change: (inout ReminderItem) -> Void) throws {
    let store = openEventStore()
    try requireAccess(store, .reminder)
    var items = try resolveReminders(store, try noteReferences(ids))
    for index in items.indices { change(&items[index]) }
    let saved = try store.saveReminders(items)
    try output.writeBatch(action, items: try eventJSON(saved), key: "reminders", summary: "\(action): \(saved.count) reminders \(summary)", notesSync: false)
}

struct CompleteReminders: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "done", abstract: "Mark reminders completed", discussion: "Takes 1 or more ids, or - for ids from stdin. Saves once. Example: abdy reminders done <id> <id>")
    @Argument(help: ArgumentHelp("1 or more reminders, by \(EventHelp.reminder), or - for ids from stdin")) var ids: [String]

    func run() throws {
        try updateReminders(output, action: "reminders done", ids: ids, summary: "completed") { $0.completed = true; $0.completionDate = Date() }
    }
}

struct ReopenReminders: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "undone", abstract: "Mark reminders open again", discussion: "Takes 1 or more ids, or - for ids from stdin. Saves once. Example: abdy reminders undone <id>")
    @Argument(help: ArgumentHelp("1 or more reminders, by \(EventHelp.reminder), or - for ids from stdin")) var ids: [String]

    func run() throws {
        try updateReminders(output, action: "reminders undone", ids: ids, summary: "reopened") { $0.completed = false; $0.completionDate = nil }
    }
}

struct MoveReminders: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "mv", abstract: "Move reminders to another list", discussion: "Takes 1 or more ids, or - for ids from stdin. Saves once. Example: abdy reminders mv <id> --list Shopping")
    @Argument(help: ArgumentHelp("1 or more reminders, by \(EventHelp.reminder), or - for ids from stdin")) var ids: [String]
    @Option(help: ArgumentHelp("Target list, by \(EventHelp.list)")) var list: String

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let target = try resolveCalendar(store, kind: .reminder, list)
        guard !target.readOnly else { throw NotesError(description: "List \(target.title) is read-only and cannot be the target") }
        try updateReminders(output, action: "reminders mv", ids: ids, summary: "to \(target.title)") { $0.listID = target.id }
    }
}

struct RemoveReminders: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete reminders", discussion: "Deletes for good, Reminders has no trash. Takes 1 or more ids, or - for ids from stdin. Example: abdy reminders rm <id>")
    @Argument(help: ArgumentHelp("1 or more reminders, by \(EventHelp.reminder), or - for ids from stdin")) var ids: [String]

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let items = try resolveReminders(store, try noteReferences(ids))
        try store.removeReminders(items.map(\.id))
        try output.writeBatch("reminders rm", items: try eventJSON(items), key: "reminders", summary: "reminders rm: \(items.count) reminders deleted", notesSync: false)
    }
}
