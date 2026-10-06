import ArgumentParser
import AppKit
import Foundation
import NotesNative

struct LocalNoteOptions: ParsableArguments {
    @Argument(help: ReferenceHelp.note) var id: String

    func open(readOnly: Bool) throws -> NBNotes {
        try openLocalNotes(readOnly: readOnly)
    }
}

func quitNotes(_ applications: [NSRunningApplication]) throws {
    for application in applications where !application.isTerminated {
        guard application.terminate() else { throw NotesError(description: "Notes refused to quit") }
    }
    let deadline = Date().addingTimeInterval(10)
    while applications.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard applications.allSatisfy(\.isTerminated) else { throw NotesError(description: "Notes has not quit") }
}

func openLocalNotes(readOnly: Bool) throws -> NBNotes {
    if !readOnly { try quitNotes(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes")) }
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    try requireReadableDatabase(url)
    return try NBNotes(url: url, readOnly: readOnly)
}

func requireReadableDatabase(_ url: URL) throws {
    try requireReadable(url, what: "the Notes database")
}

func requireReadable(_ url: URL, what: String) throws {
    let descriptor = open(url.path, O_RDONLY)
    if descriptor >= 0 { close(descriptor); return }
    guard errno == EPERM || errno == EACCES else { return }
    let holder = ProcessInfo.processInfo.environment["ABDY_IN_APP"] != nil ? "Abdy.app (\(AppBundle.bundle.path))" : "this terminal application"
    throw NotesError(description: "macOS blocks \(holder) from reading \(what) \(url.path). Allow it in System Settings, Privacy and Security, Full Disk Access, then run the command again")
}

struct PositionOptions: ParsableArguments {
    @Option(help: "Insert before this unique text") var before: String?
    @Option(help: "Insert after this unique text") var after: String?

    func values() throws -> [String: Any] {
        guard before == nil || after == nil else { throw ValidationError("choose either --before or --after") }
        var values: [String: Any] = [:]
        if let before { values["before"] = before }
        if let after { values["after"] = after }
        return values
    }
}

struct Inspect: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(abstract: "Read native text, formatting, attachments, tags, links and tables", discussion: "Reads this computer's Notes database without changing it. Objects appear in text as U+FFFC. Use returned ids for attachments and links. Add --json for structured data. Example: abdy notes inspect <id>")
    @OptionGroup var note: LocalNoteOptions

    func run() throws {
        try output.write(note.open(readOnly: true).readNote(note.id))
    }
}

struct Edit: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(abstract: "Replace visible text while preserving attachments and formatting", discussion: "Matches literal visible text, not HTML. Missing or ambiguous matches fail without saving. Use --all for every match. Cannot match across object markers. Saves locally, run abdy notes sync after the last write to send changes to iCloud. Example: abdy notes edit <id> --find draft --with final")
    @OptionGroup var note: LocalNoteOptions
    @Option(help: "Exact visible text to find") var find: String
    @Option(name: .customLong("with"), help: "Replacement text") var replacement: String
    @Flag(help: "Replace all occurrences") var all = false

    func run() throws {
        let store = try note.open(readOnly: false)
        try output.writeAction("edit", store.editNote(note.id, operation: "replace", options: ["find": find, "replacement": replacement, "all": all]))
    }
}

struct Insert: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(abstract: "Insert visible text at an anchor, or append it", discussion: "Without an anchor, appends plain text. --before and --after require one exact match and cannot be combined. Saves locally, run abdy notes sync after the last write to send changes to iCloud. Example: abdy notes insert <id> --text 'See also: ' --after Summary")
    @OptionGroup var note: LocalNoteOptions
    @OptionGroup var position: PositionOptions
    @Option(help: "Text to insert") var text: String

    func run() throws {
        var options = try position.values()
        options["text"] = text
        try output.writeAction("insert", note.open(readOnly: false).editNote(note.id, operation: "insert", options: options))
    }
}

struct Format: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(abstract: "Format selected text or its paragraphs, including checklists", discussion: "Inline styles affect selected text. Paragraph styles affect each selected paragraph. --off removes an inline style. --style body removes lists or headings. Checklist items are unchecked unless --checked is set. Saves locally, run abdy notes sync after the last write to send changes to iCloud. Example: abdy notes format <id> --find 'Buy milk' --style checklist --checked")
    @OptionGroup var note: LocalNoteOptions
    @Option(help: "Exact visible text to select") var find: String
    @Option(help: "bold, italic, underline, strikethrough, title, heading, subheading, body, monospace, bullet, numbered, checklist") var style: String
    @Flag(help: "Remove the selected inline style") var off = false
    @Flag(help: "Check checklist items") var checked = false
    @Flag(help: "Format all occurrences") var all = false

    func run() throws {
        try output.writeAction("format", note.open(readOnly: false).editNote(note.id, operation: "format", options: ["find": find, "style": style, "off": off, "checked": checked, "all": all]))
    }
}

struct Tags: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(abstract: "List, add, remove or rename native tags", discussion: """
        Without ids lists every tag of the database with its note count, 1 per line: #name<TAB>count.
        With ids and no option prints the tags of each note on 1 line. Add --json for tag ids.
        --add and --remove take 1 or more ids, or - for ids from stdin, and save once. 1 invalid name or refusal cancels the batch.
        --remove without ids takes the tag off every note. --rename with --to renames the tag everywhere.
        Separate names with slashes, commas or whitespace. Each name becomes a distinct native tag, not text.
        Search with ls --tag. Saves locally, run abdy notes sync after the last write to send changes to iCloud.

        EXAMPLES
          abdy notes tags
          abdy notes tags <id> --add 'invoices/tech,other'
          abdy notes tags <id> <id> --remove draft
          abdy notes tags --remove draft
          abdy notes tags --rename draft --to review
        """)
    @Argument(help: ArgumentHelp("Notes, by \(ReferenceHelp.noteText), or - for ids from stdin")) var ids: [String] = []
    @Option(help: ArgumentHelp("Native tags to add, \(ReferenceHelp.tag), separated by slash, comma or whitespace")) var add: String?
    @Option(help: ArgumentHelp("Native tags to remove, \(ReferenceHelp.tag) or tag id, separated by slash, comma or whitespace")) var remove: String?
    @Option(help: ArgumentHelp("Tag to rename everywhere, \(ReferenceHelp.tag)")) var rename: String?
    @Option(help: "New name for --rename") var to: String?

    func run() throws {
        let chosen = [add, remove, rename].compactMap { $0 }.count
        guard chosen <= 1 else { throw ValidationError("choose one of --add, --remove or --rename") }
        guard (rename == nil) == (to == nil) else { throw ValidationError("--rename needs --to") }
        guard add == nil || !ids.isEmpty else { throw ValidationError("--add needs note ids") }
        guard rename == nil || ids.isEmpty else { throw ValidationError("--rename takes no note ids") }
        let store = try openLocalNotes(readOnly: chosen == 0)
        if let rename, let to {
            let notes = try store.renameTag(rename, to: to)
            return try output.writeBatch("tags rename", items: notes, key: "notes", fields: ["from": rename, "to": to], summary: "tags rename: #\(rename) to #\(to) on \(notes.count) notes")
        }
        if let add {
            let notes = try store.editNotes(try noteReferences(ids), operation: "tag-add", options: ["name": add])
            return try output.writeBatch("tags add", items: notes, key: "notes", summary: "tags add: \(notes.count) notes")
        }
        if let remove {
            let notes = try store.editNotes(ids.isEmpty ? nil : try noteReferences(ids), operation: "tag-remove", options: ["name": remove])
            return try output.writeBatch("tags rm", items: notes, key: "notes", summary: "tags rm: \(notes.count) notes")
        }
        if ids.isEmpty {
            let tags = try store.listTags()
            let lines = try tags.map { tag -> String in
                guard let name = tag["name"] as? String, let count = tag["noteCount"] as? Int else { throw NotesError(description: "Notes returned invalid tag data") }
                return "\(name)\t\(count)"
            }
            try output.write(tags, text: lines.joined(separator: "\n"))
            return output.summary("\(tags.count) tags")
        }
        let notes = try noteReferences(ids).map { try store.readNote($0) }
        let lines = try notes.map { note -> String in
            guard let tags = note["tags"] as? [[String: Any]] else { throw NotesError(description: "Notes returned invalid tag data") }
            return tags.compactMap { $0["name"] as? String }.joined(separator: " ")
        }
        let objects = notes.map { ["id": $0["id"]!, "tags": $0["tags"]!] }
        try output.write(objects.count == 1 ? objects[0] : objects, text: lines.joined(separator: "\n"))
    }
}

struct Attachments: ParsableCommand {
    @OptionGroup var output: OutputOptions
    enum Action: String, CaseIterable, ExpressibleByArgument { case ls, export, add, rm, replace, mv, view }
    static let optionsForActions: [String: Set<Action>] = [
        "attachment": [.export, .rm, .replace, .mv, .view], "file": [.export, .add, .replace],
        "directory": [.export], "to": [.mv], "size": [.view], "before": [.add, .mv], "after": [.add, .mv]
    ]
    static let requiredOptionsForActions: [Action: Set<String>] = [
        .add: ["file"], .rm: ["attachment"], .replace: ["attachment", "file"],
        .mv: ["attachment", "to"], .view: ["attachment", "size"]
    ]
    static let configuration = CommandConfiguration(abstract: "List, export, add, remove, replace, move or resize note attachments", discussion: """
        Get attachment ids with ls. Export before rm to keep a copy.
        Edits print the note UUID. Export prints the saved path.
        Saves locally, run abdy notes sync after the last write to send changes to iCloud.

        EXAMPLES
          abdy notes attachments ls <id>
          abdy notes attachments add <id> --file report.pdf
          abdy notes attachments export <id> --attachment <attachment-id> --file saved.pdf
          abdy notes attachments export <id> --directory saved-files
        """)
    @Argument(help: "ls, export, add, rm, replace, mv, view") var action: Action
    @OptionGroup var note: LocalNoteOptions
    @OptionGroup var position: PositionOptions
    @Option(help: ReferenceHelp.attachment) var attachment: String?
    @Option(help: "Input file for add or replace, output file for export") var file: String?
    @Option(help: "Export all files, or the selected attachment, into this directory") var directory: String?
    @Option(help: "Destination note for mv, same forms as the note argument") var to: String?
    @Option(help: "Notes view size: 0 (default), 1 or 2") var size: Int?

    func validate() throws {
        let options = ["attachment": attachment != nil, "file": file != nil, "directory": directory != nil,
                       "to": to != nil, "size": size != nil, "before": position.before != nil, "after": position.after != nil]
        for (name, supplied) in options where supplied && Self.optionsForActions[name]?.contains(action) != true {
            throw ValidationError("--\(name) is not valid for attachments \(action.rawValue)")
        }
        _ = try position.values()
        if let size, !(0...2).contains(size) { throw ValidationError("--size must be 0, 1 or 2") }
    }

    func run() throws {
        try validate()
        let supplied = ["attachment": attachment != nil, "file": file != nil, "to": to != nil, "size": size != nil]
        for name in Self.requiredOptionsForActions[action] ?? [] where supplied[name] != true { throw ValidationError("--\(name) is required") }
        if action == .export { try validateExportDestination() }
        let attachedFile = try action == .add || action == .replace ? file.map(readableFilePath) : nil
        let store = try note.open(readOnly: action == .ls || action == .export)
        if action == .ls {
            let data = try store.readNote(note.id)
            return try output.write(["id": data["id"]!, "attachments": data["attachments"]!])
        }
        if action == .export {
            let data = try store.readNote(note.id)
            guard let owner = data["id"] as? String, let items = data["attachments"] as? [[String: Any]] else {
                throw NotesError(description: "Notes returned invalid attachments")
            }
            var command = self
            if let attachment { command.attachment = try store.attachmentID(forReference: attachment, note: note.id) }
            let files = try command.exportFiles(items)
            if file != nil, let saved = files.first {
                try output.write(["path": saved["path"]!, "id": owner, "attachment": saved["attachment"]!], text: saved["path"]!)
            } else {
                try output.write(["id": owner, "files": files], text: files.map { $0["path"]! }.joined(separator: "\n"))
            }
            return
        }
        var options = try position.values()
        if action != .add {
            guard let attachment else { throw ValidationError("--attachment is required") }
            options["attachment"] = attachment
        }
        if let attachedFile { options["file"] = attachedFile }
        if action == .mv {
            guard let to else { throw ValidationError("--to is required") }
            options["target"] = to
        }
        if action == .view {
            guard let size, (0...2).contains(size) else { throw ValidationError("--size must be 0, 1 or 2") }
            options["size"] = size
        }
        let operation = action == .rm ? "remove" : action == .mv ? "move" : action.rawValue
        try output.writeAction("attachments " + action.rawValue, store.editNote(note.id, operation: "attachment-" + operation, options: options))
    }

    func validateExportDestination() throws {
        guard (file != nil) != (directory != nil), file == nil || attachment != nil else {
            throw ValidationError("export requires --directory or both --attachment and --file")
        }
    }

    func exportFiles(_ items: [[String: Any]]) throws -> [[String: String]] {
        try validateExportDestination()
        let selected = items.filter { attachment == nil ? $0["kind"] as? String != "table" : $0["id"] as? String == attachment }
        guard attachment == nil || selected.count == 1 else { throw NotesError(description: "attachment not found in this note") }
        let sources = try selected.map { item -> (id: String, source: URL) in
            guard item["kind"] as? String != "table" else { throw NotesError(description: "native tables are not exported, read them with abdy notes table ls") }
            guard let id = item["id"] as? String, let path = item["path"] as? String, item["available"] as? Bool == true else {
                throw NotesError(description: "attachment file is not available locally")
            }
            return (id, URL(fileURLWithPath: path))
        }
        guard !sources.isEmpty else { throw NotesError(description: "note has no files to export") }
        return try copyAttachmentFiles(sources, file: file, directory: directory)
    }
}

func copyAttachmentFiles(_ sources: [(id: String, source: URL)], file: String?, directory: String?) throws -> [[String: String]] {
    var copies: [(URL, URL, String)] = []
    var names = Set<String>()
    for (id, source) in sources {
        guard FileManager.default.fileExists(atPath: source.path) else { throw NotesError(description: "attachment file is not available locally") }
        try requireReadable(source, what: "the attachment file")
        let destination: URL
        if let file { destination = URL(fileURLWithPath: file) }
        else {
            let folder = URL(fileURLWithPath: directory!)
            var name = source.lastPathComponent
            var number = 2
            while !names.insert(name.lowercased()).inserted {
                name = source.deletingPathExtension().lastPathComponent + " (\(number))" + (source.pathExtension.isEmpty ? "" : "." + source.pathExtension)
                number += 1
            }
            destination = folder.appendingPathComponent(name)
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw NotesError(description: "destination already exists: \(destination.path)")
        }
        copies.append((source, destination, id))
    }
    if let directory {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: directory), withIntermediateDirectories: true)
    }
    var exported: [[String: String]] = []
    for (source, destination, id) in copies {
        try FileManager.default.copyItem(at: source, to: destination)
        exported.append(["attachment": id, "path": destination.path])
    }
    return exported
}

struct Links: ParsableCommand {
    @OptionGroup var output: OutputOptions
    enum Action: String, CaseIterable, ExpressibleByArgument { case ls, add, rm }
    static let optionsForActions: [String: Set<Action>] = ["to": [.add], "link": [.rm], "before": [.add], "after": [.add]]
    static let requiredOptionsForActions: [Action: Set<String>] = [.add: ["to"], .rm: ["link"]]
    static let configuration = CommandConfiguration(abstract: "Create, list and remove native cross-references between notes", discussion: """
        Links are one-way. Get link ids with ls.
        rm removes the link, not the target note.
        Saves locally, run abdy notes sync after the last write to send changes to iCloud.

        EXAMPLES
          abdy notes links add <source-id> --to <target-id>
          abdy notes links ls <source-id>
          abdy notes links rm <source-id> --link <link-id>
        """)
    @Argument(help: "ls, add or rm") var action: Action
    @OptionGroup var note: LocalNoteOptions
    @OptionGroup var position: PositionOptions
    @Option(help: "Target note for add, same forms as the note argument") var to: String?
    @Option(help: "Link UUID or unique prefix from links ls, required for rm") var link: String?

    func validate() throws {
        let options = ["to": to != nil, "link": link != nil, "before": position.before != nil, "after": position.after != nil]
        for (name, supplied) in options where supplied && Self.optionsForActions[name]?.contains(action) != true {
            throw ValidationError("--\(name) is not valid for links \(action.rawValue)")
        }
        _ = try position.values()
    }

    func run() throws {
        try validate()
        var options = try position.values()
        if action == .add {
            guard let to else { throw ValidationError("add requires --to") }
            options["target"] = to
        }
        if action == .rm {
            guard let link else { throw ValidationError("rm requires --link") }
            options["link"] = link
        }
        let store = try note.open(readOnly: action == .ls)
        if action == .ls {
            let data = try store.readNote(note.id)
            return try output.write(["id": data["id"]!, "links": data["links"]!])
        }
        try output.writeAction("links " + action.rawValue, store.editNote(note.id, operation: action == .add ? "link-add" : "link-remove", options: options))
    }
}

struct Search: ParsableCommand {
    @OptionGroup var output: OutputOptions
    enum Field: String, ExpressibleByArgument { case all, id, title, text, attachment, tag, link, url, document }
    static let configuration = CommandConfiguration(abstract: "Find notes by text, title, id, table cells, tags, links or attachment filename", discussion: """
        Prints only note UUIDs, one per line. No matches produce no stdout.
        Fuzzy matching is enabled by default. Exact matches rank first.
        all searches document contents automatically, including PDF text and image text.
        Changed documents are indexed in parallel. Later searches reuse the local index.
        Add --json for titles, excerpts and match details. Deleted notes are excluded.
        Locked notes are not searched, their number goes to stderr and skippedProtected.
        id matches exactly. tag, link and url search native tags, note links and web addresses.
        Without --limit prints the first 50 results. JSON total has the full count.
        --show prints each match in full, the UUID, title, folder, date and matched fields, then the show text.
        With --json, --show adds the show fields without runs: text, textLength, tables, links and cloud state.
        --chars N keeps the first N characters of each text, textLength keeps the full length.

        EXAMPLES
          abdy notes search invoice
          abdy notes search invoice --show --limit 5
          abdy notes search "Invoice number" --field document
          abdy notes search project --field tag --show --chars 2000 --json
        """)
    @Argument(help: "Nonempty text or id fragment to find") var query: String
    @Option(help: "all, id, title, text, attachment, tag, link, url or document") var field: Field = .all
    @Option(help: ArgumentHelp("Only notes of this folder and its subfolders, by \(ReferenceHelp.folder)")) var folder: String?
    @OptionGroup var reading: ReadingOptions

    func run() throws {
        var options = try reading.options()
        options["field"] = field.rawValue
        if options["limit"] == nil { options["limit"] = 50 }
        guard folder != nil || !reading.noRecursive else { throw ValidationError("--no-recursive needs --folder") }
        if let folder { options["folder"] = folder }
        let result = try openLocalNotes(readOnly: true).search(query, options: options)
        guard let notes = result["notes"] as? [[String: Any]] else { throw NotesError(description: "Notes returned invalid search results") }
        if let errors = result["documentErrors"] as? [[String: String]] {
            for error in errors {
                guard let attachment = error["attachment"], let message = error["error"] else { throw NotesError(description: "Notes returned invalid document diagnostics") }
                FileHandle.standardError.write(Data("Document error: \(attachment) \(message)\n".utf8))
            }
        }
        try output.write(result, text: try reading.render(notes))
        guard let total = result["total"] as? Int else { throw NotesError(description: "Notes returned invalid search count") }
        output.summary("\(notes.count) of \(total) notes")
        if let skipped = result["skippedProtected"] as? Int, skipped > 0 { output.summary("\(skipped) locked notes not searched") }
    }
}
