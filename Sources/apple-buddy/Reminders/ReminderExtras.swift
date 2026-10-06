import ArgumentParser
import Foundation

func resolveSection(_ store: EventStore, listID: String, _ reference: String) throws -> ReminderSection {
    let sections = try store.sections(listID: listID)
    if let exact = sections.first(where: { $0.id == reference }) { return exact }
    if reference.count >= 8 {
        let prefixed = sections.filter { $0.id.lowercased().hasPrefix(reference.lowercased()) }
        if prefixed.count == 1 { return prefixed[0] }
    }
    let named = sections.filter { $0.title.caseInsensitiveCompare(reference) == .orderedSame }
    if named.count == 1 { return named[0] }
    if named.count > 1 { throw NotesError(description: "Section name is ambiguous: \(reference). Use a UUID from abdy reminders sections: " + named.map { "\($0.title) \($0.id)" }.joined(separator: ", ")) }
    throw NotesError(description: "Section not found in this list: \(reference). Use a name, a UUID or its prefix from abdy reminders sections, create one with abdy reminders mksection")
}

func resolveAttachment(_ item: ReminderItem, _ reference: String) throws -> ReminderAttachment {
    if let exact = item.attachments.first(where: { $0.id == reference }) { return exact }
    let prefixed = reference.count >= 8 ? item.attachments.filter { $0.id.lowercased().hasPrefix(reference.lowercased()) } : []
    if prefixed.count == 1 { return prefixed[0] }
    if prefixed.count > 1 { throw NotesError(description: "Attachment prefix is ambiguous: \(reference). Use a longer prefix or the UUID") }
    throw NotesError(description: "Attachment not found in this reminder: \(reference). Use a UUID or its prefix of at least 8 characters from abdy reminders attachments ls")
}

func tagNames(_ text: String) -> [String] {
    var seen = Set<String>()
    return text.split { $0 == "," || $0 == "/" || $0.isWhitespace }.map { String($0.drop { $0 == "#" }) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
}

func attachmentRows(_ attachments: [ReminderAttachment]) -> String {
    attachments.map { [$0.id, $0.kind.rawValue, $0.url ?? $0.name ?? "", $0.size.map(String.init) ?? ""].joined(separator: "\t") }.joined(separator: "\n")
}

struct ReminderAttachments: ParsableCommand {
    @OptionGroup var output: OutputOptions
    enum Action: String, CaseIterable, ExpressibleByArgument { case ls, add, export, rm }
    static let optionsForActions: [String: Set<Action>] = ["file": [.add, .export], "url": [.add], "attachment": [.export, .rm], "directory": [.export]]
    static let requiredOptionsForActions: [Action: Set<String>] = [.rm: ["attachment"]]
    static let configuration = CommandConfiguration(commandName: "attachments", abstract: "List, add, export or remove reminder attachments", discussion: """
        add takes an image or any file with --file, or a web link with --url. Images show as pictures in Reminders.
        export copies files into --directory, or 1 attachment with --attachment and --file. Export never overwrites.
        Get attachment ids with ls. Edits print the reminder UUID, export prints the saved paths.

        EXAMPLES
          abdy reminders attachments ls <id>
          abdy reminders attachments add <id> --file photo.jpg
          abdy reminders attachments add <id> --url https://example.com/ticket
          abdy reminders attachments export <id> --directory saved-files
          abdy reminders attachments rm <id> --attachment <attachment-id>
        """)
    @Argument(help: "ls, add, export, rm") var action: Action
    @Argument(help: ArgumentHelp(EventHelp.reminder)) var id: String
    @Option(help: "File to add, or the output file for export with --attachment") var file: String?
    @Option(help: "Web link to add") var url: String?
    @Option(help: "Attachment UUID or unique prefix of at least 8 characters from attachments ls") var attachment: String?
    @Option(help: "Export every file, or the selected attachment, into this directory") var directory: String?

    func validate() throws {
        let supplied = ["file": file != nil, "url": url != nil, "attachment": attachment != nil, "directory": directory != nil]
        for (name, given) in supplied where given && Self.optionsForActions[name]?.contains(action) != true { throw ValidationError("--\(name) is not valid for attachments \(action.rawValue)") }
        switch action {
        case .add: guard (file != nil) != (url != nil) else { throw ValidationError("add takes --file or --url") }
        case .rm: guard attachment != nil else { throw ValidationError("--attachment is required") }
        case .export: guard (file != nil) != (directory != nil), file == nil || attachment != nil else { throw ValidationError("export requires --directory or both --attachment and --file") }
        case .ls: break
        }
    }

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let item = try resolveReminders(store, [id])[0]
        switch action {
        case .ls:
            try output.write(["id": item.id, "attachments": try eventJSON(item.attachments)], text: attachmentRows(item.attachments))
            output.summary("\(item.attachments.count) attachments")
        case .add:
            let added = try store.addAttachment(item.id, file: file, url: url)
            var data = try eventJSON(try store.reminder(item.id) ?? item) as? [String: Any] ?? [:]
            data["attachment"] = added.id
            try output.writeAction("attachments add", data, notesSync: false)
        case .export:
            var selected = item.attachments.filter { $0.kind != .url }
            if let attachment { selected = [try resolveAttachment(item, attachment)] }
            let sources = try selected.map { attachment -> (id: String, source: URL) in
                guard let path = attachment.path else { throw NotesError(description: "attachment \(attachment.id) is a link, not a file") }
                return (attachment.id, URL(fileURLWithPath: path))
            }
            guard !sources.isEmpty else { throw NotesError(description: "reminder has no files to export") }
            let files = try copyAttachmentFiles(sources, file: file, directory: directory)
            if file != nil, let saved = files.first {
                try output.write(["path": saved["path"]!, "id": item.id, "attachment": saved["attachment"]!], text: saved["path"]!)
            } else {
                try output.write(["id": item.id, "files": files], text: files.map { $0["path"]! }.joined(separator: "\n"))
            }
        case .rm:
            let target = try resolveAttachment(item, attachment!)
            try store.removeAttachment(item.id, attachment: target.id)
            var data = try eventJSON(try store.reminder(item.id) ?? item) as? [String: Any] ?? [:]
            data["attachment"] = target.id
            data["deleted"] = true
            try output.writeAction("attachments rm", data, notesSync: false)
        }
    }
}

struct FlagReminders: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "flag", abstract: "Flag reminders", discussion: "Takes 1 or more ids, or - for ids from stdin. Example: abdy reminders flag <id>")
    @Argument(help: ArgumentHelp("1 or more reminders, by \(EventHelp.reminder), or - for ids from stdin")) var ids: [String]

    func run() throws {
        try updateReminders(output, action: "reminders flag", ids: ids, summary: "flagged") { $0.flagged = true }
    }
}

struct UnflagReminders: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "unflag", abstract: "Remove the flag from reminders", discussion: "Takes 1 or more ids, or - for ids from stdin. Example: abdy reminders unflag <id>")
    @Argument(help: ArgumentHelp("1 or more reminders, by \(EventHelp.reminder), or - for ids from stdin")) var ids: [String]

    func run() throws {
        try updateReminders(output, action: "reminders unflag", ids: ids, summary: "unflagged") { $0.flagged = false }
    }
}

struct Subtasks: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "subtasks", abstract: "List the subtasks of a reminder", discussion: """
        Prints open subtasks as UUIDs, 1 per line, --all includes completed ones. Create a subtask with add --parent.

        EXAMPLE
          abdy reminders subtasks <id> --long
        """)
    @Argument(help: ArgumentHelp(EventHelp.reminder)) var id: String
    @Flag(help: "Open and completed subtasks") var all = false
    @OptionGroup var paging: ListPaging

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let parent = try resolveReminders(store, [id])[0]
        let items = try store.reminders(listIDs: nil).filter { $0.parentID == parent.id && (all || !$0.completed) }
        let page = try paging.page(items)
        try output.write(try eventJSON(page), text: paging.long ? reminderRows(page, lists: try store.calendars(.reminder)) : page.map(\.id).joined(separator: "\n"))
        output.summary(paging.summary(page.count, of: items.count, "subtasks"))
    }
}

struct ReminderTags: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "tags", abstract: "List, add or remove reminder tags", discussion: """
        Without ids prints every tag with its reminder count. With ids prints the tags of those reminders.
        --add and --remove take names separated by comma or whitespace, with or without #, and save once.

        EXAMPLES
          abdy reminders tags
          abdy reminders tags <id> --add errands,urgent
          abdy reminders tags <id> <id> --remove urgent
        """)
    @Argument(help: ArgumentHelp("Reminders, by \(EventHelp.reminder), or - for ids from stdin")) var ids: [String] = []
    @Option(help: "Tags to add, separated by comma or whitespace") var add: String?
    @Option(help: "Tags to remove, separated by comma or whitespace") var remove: String?

    func run() throws {
        guard add == nil || remove == nil else { throw ValidationError("choose either --add or --remove") }
        guard (add == nil && remove == nil) || !ids.isEmpty else { throw ValidationError("--add and --remove need reminder ids") }
        let store = openEventStore()
        try requireAccess(store, .reminder)
        if let add {
            let names = tagNames(add)
            guard !names.isEmpty else { throw ValidationError("--add needs at least 1 tag name") }
            return try updateReminders(output, action: "reminders tags add", ids: ids, summary: "tagged") { item in
                item.tags += names.filter { name in !item.tags.contains { $0.caseInsensitiveCompare(name) == .orderedSame } }
            }
        }
        if let remove {
            let names = tagNames(remove)
            guard !names.isEmpty else { throw ValidationError("--remove needs at least 1 tag name") }
            return try updateReminders(output, action: "reminders tags rm", ids: ids, summary: "untagged") { item in
                item.tags.removeAll { tag in names.contains { $0.caseInsensitiveCompare(tag) == .orderedSame } }
            }
        }
        if ids.isEmpty {
            var counts: [String: Int] = [:]
            for item in try store.reminders(listIDs: nil) { for tag in item.tags { counts[tag, default: 0] += 1 } }
            let tags = counts.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { ["name": $0, "reminderCount": counts[$0]!] as [String: Any] }
            try output.write(tags, text: tags.map { "\($0["name"]!)\t\($0["reminderCount"]!)" }.joined(separator: "\n"))
            return output.summary("\(tags.count) tags")
        }
        let items = try resolveReminders(store, try noteReferences(ids))
        let objects = items.map { ["id": $0.id, "tags": $0.tags] as [String: Any] }
        try output.write(objects.count == 1 ? objects[0] : objects, text: items.map { $0.tags.joined(separator: " ") }.joined(separator: "\n"))
    }
}

func sectionRows(_ sections: [ReminderSection]) -> String {
    sections.map { "\($0.id)\t\($0.title)" }.joined(separator: "\n")
}

struct ReminderSections: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "sections", abstract: "List the sections of a reminder list", discussion: """
        Prints 1 line per section: uuid and title, tab separated. Assign reminders with add --section or mv --section.

        EXAMPLE
          abdy reminders sections --list Groceries
        """)
    @Option(help: ArgumentHelp("List, by \(EventHelp.list)")) var list: String

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let sections = try store.sections(listID: try resolveCalendar(store, kind: .reminder, list).id)
        try output.write(try eventJSON(sections), text: sectionRows(sections))
        output.summary("\(sections.count) sections")
    }
}

struct MakeSection: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "mksection", abstract: "Create a section in a reminder list", discussion: "Prints the section UUID. Example: abdy reminders mksection Produce --list Groceries")
    @Argument(help: "Section title") var title: String
    @Option(help: ArgumentHelp("List, by \(EventHelp.list)")) var list: String

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let target = try resolveCalendar(store, kind: .reminder, list)
        guard !target.readOnly else { throw NotesError(description: "List \(target.title) is read-only and cannot hold sections") }
        var data = try eventJSON(try store.createSection(listID: target.id, title: title)) as? [String: Any] ?? [:]
        data["list"] = target.title
        try output.writeAction("mksection", data, notesSync: false)
    }
}

struct RenameSection: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "renamesection", abstract: "Rename a section", discussion: "Example: abdy reminders renamesection Produce --list Groceries --name Vegetables")
    @Argument(help: "Section title, UUID or unique prefix of at least 8 characters from reminders sections") var section: String
    @Option(help: ArgumentHelp("List, by \(EventHelp.list)")) var list: String
    @Option(name: .customLong("name"), help: "New section title") var newName: String

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let target = try resolveCalendar(store, kind: .reminder, list)
        let found = try resolveSection(store, listID: target.id, section)
        var data = try eventJSON(try store.renameSection(found.id, to: newName)) as? [String: Any] ?? [:]
        data["list"] = target.title
        try output.writeAction("renamesection", data, notesSync: false)
    }
}

struct RemoveSection: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "rmsection", abstract: "Delete a section, its reminders stay in the list", discussion: "Example: abdy reminders rmsection Produce --list Groceries")
    @Argument(help: "Section title, UUID or unique prefix of at least 8 characters from reminders sections") var section: String
    @Option(help: ArgumentHelp("List, by \(EventHelp.list)")) var list: String

    func run() throws {
        let store = openEventStore()
        try requireAccess(store, .reminder)
        let target = try resolveCalendar(store, kind: .reminder, list)
        let found = try resolveSection(store, listID: target.id, section)
        try store.removeSection(found.id)
        var data = try eventJSON(found) as? [String: Any] ?? [:]
        data["list"] = target.title
        data["deleted"] = true
        try output.writeAction("rmsection", data, notesSync: false)
    }
}
