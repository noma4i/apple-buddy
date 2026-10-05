import ArgumentParser
import AppKit
import Foundation
import NotesNative

struct LocalNoteOptions: ParsableArguments {
    @Argument(help: "Note id from ls or new") var id: String

    func open(readOnly: Bool) throws -> NBNotes {
        try openLocalNotes(readOnly: readOnly)
    }
}

func quitNotes(_ applications: [NSRunningApplication]) throws {
    for application in applications where !application.isTerminated {
        guard application.terminate() else { throw ValidationError("Notes refused to quit") }
    }
    let deadline = Date().addingTimeInterval(10)
    while applications.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard applications.allSatisfy(\.isTerminated) else { throw ValidationError("Notes has not quit") }
}

func openLocalNotes(readOnly: Bool) throws -> NBNotes {
    if !readOnly { try quitNotes(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes")) }
    let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
    return try NBNotes(url: url, readOnly: readOnly)
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
    static let configuration = CommandConfiguration(abstract: "Read native text, formatting, attachments, tags, links and tables", discussion: "Reads this computer's Notes database without changing it. Objects appear in text as U+FFFC. Use returned ids for attachments and links. Add --json for structured data. Example: nb inspect <id>")
    @OptionGroup var note: LocalNoteOptions

    func run() throws {
        try output.write(note.open(readOnly: true).readNote(note.id))
    }
}

struct Edit: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(abstract: "Replace visible text while preserving attachments and formatting", discussion: "Matches literal visible text, not HTML. Missing or ambiguous matches fail without saving. Use --all for every match. Cannot match across object markers. Example: nb edit <id> --find draft --with final")
    @OptionGroup var note: LocalNoteOptions
    @Option(help: "Exact visible text to find") var find: String
    @Option(name: .customLong("with"), help: "Replacement text") var replacement: String
    @Flag(help: "Replace all occurrences") var all = false

    func run() throws {
        let store = try note.open(readOnly: false)
        try output.writeAction("edit", store.editNote(note.id, operation: "replace", options: ["find": find, "replacement": replacement, "all": all]), text: note.id)
    }
}

struct Insert: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(abstract: "Insert visible text at an anchor, or append it", discussion: "Without an anchor, appends plain text. --before and --after require one exact match and cannot be combined. Example: nb insert <id> --text 'See also: ' --after Summary")
    @OptionGroup var note: LocalNoteOptions
    @OptionGroup var position: PositionOptions
    @Option(help: "Text to insert") var text: String

    func run() throws {
        var options = try position.values()
        options["text"] = text
        try output.writeAction("insert", note.open(readOnly: false).editNote(note.id, operation: "insert", options: options), text: note.id)
    }
}

struct Format: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(abstract: "Format selected text or its paragraphs, including checklists", discussion: "Inline styles affect selected text. Paragraph styles affect each selected paragraph. --off removes an inline style. --style body removes lists or headings. Checklist items are unchecked unless --checked is set. Example: nb format <id> --find 'Buy milk' --style checklist --checked")
    @OptionGroup var note: LocalNoteOptions
    @Option(help: "Exact visible text to select") var find: String
    @Option(help: "bold, italic, underline, strikethrough, title, heading, subheading, body, monospace, bullet, numbered, checklist") var style: String
    @Flag(help: "Remove the selected inline style") var off = false
    @Flag(help: "Check checklist items") var checked = false
    @Flag(help: "Format all occurrences") var all = false

    func run() throws {
        try output.writeAction("format", note.open(readOnly: false).editNote(note.id, operation: "format", options: ["find": find, "style": style, "off": off, "checked": checked, "all": all]), text: note.id)
    }
}

struct Tags: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(abstract: "List, add or remove native tags on a note", discussion: "Without --add or --remove, lists tags. Add --json for structured data. Separate names with slashes, commas or whitespace. Each name becomes a distinct native tag, not text. Duplicates are ignored. Invalid names reject the whole batch. --remove uses the same separators and affects only this note. Search with ls --tag. Example: nb tags <id> --add 'invoices/tech,other'")
    @OptionGroup var note: LocalNoteOptions
    @Option(help: "Native tags to add, separated by slash, comma or whitespace") var add: String?
    @Option(help: "Native tags to remove, separated by slash, comma or whitespace") var remove: String?

    func run() throws {
        guard add == nil || remove == nil else { throw ValidationError("choose either --add or --remove") }
        let store = try note.open(readOnly: add == nil && remove == nil)
        if let add { return try output.writeAction("tags add", store.editNote(note.id, operation: "tag-add", options: ["name": add]), text: note.id) }
        if let remove { return try output.writeAction("tags rm", store.editNote(note.id, operation: "tag-remove", options: ["name": remove]), text: note.id) }
        try output.write(["tags": store.readNote(note.id)["tags"]!])
    }
}

struct Attachments: ParsableCommand {
    @OptionGroup var output: OutputOptions
    enum Action: String, ExpressibleByArgument { case ls, export, add, rm, replace, mv, view }
    static let configuration = CommandConfiguration(abstract: "List, export, add, remove, replace, move or resize note attachments", discussion: """
        Get attachment ids with ls. Export before rm to keep a copy.
        Edits print the note URL. Export prints the saved path.

        EXAMPLES
          nb attachments ls <id>
          nb attachments add <id> --file report.pdf
          nb attachments export <id> --attachment <attachment-id> --file saved.pdf
          nb attachments export <id> --directory saved-files
        """)
    @Argument(help: "ls, export, add, rm, replace, mv, view") var action: Action
    @OptionGroup var note: LocalNoteOptions
    @OptionGroup var position: PositionOptions
    @Option(help: "Attachment id from inspect or attachments ls") var attachment: String?
    @Option(help: "Input file for add or replace, output file for export") var file: String?
    @Option(help: "Export all files, or the selected attachment, into this directory") var directory: String?
    @Option(help: "Destination note id for mv") var to: String?
    @Option(help: "Notes view size: 0 (default), 1 or 2") var size: Int?

    func validate() throws {
        let options: [(String, Bool, [Action])] = [
            ("--attachment", attachment != nil, [.export, .rm, .replace, .mv, .view]),
            ("--file", file != nil, [.export, .add, .replace]),
            ("--directory", directory != nil, [.export]),
            ("--to", to != nil, [.mv]),
            ("--size", size != nil, [.view]),
            ("--before/--after", position.before != nil || position.after != nil, [.add, .mv])
        ]
        for (name, supplied, actions) in options where supplied && !actions.contains(action) {
            throw ValidationError("\(name) is not valid for attachments \(action.rawValue)")
        }
        _ = try position.values()
        if let size, !(0...2).contains(size) { throw ValidationError("--size must be 0, 1 or 2") }
    }

    func run() throws {
        try validate()
        let store = try note.open(readOnly: action == .ls || action == .export)
        if action == .ls { return try output.write(["attachments": store.readNote(note.id)["attachments"]!]) }
        if action == .export {
            guard let items = try store.readNote(note.id)["attachments"] as? [[String: Any]] else {
                throw ValidationError("Notes returned invalid attachments")
            }
            let files = try exportFiles(items)
            if file != nil, let saved = files.first {
                try output.write(["path": saved["path"]!, "id": note.id, "attachment": saved["attachment"]!], text: saved["path"]!)
            } else {
                try output.write(["id": note.id, "files": files], text: files.map { $0["path"]! }.joined(separator: "\n"))
            }
            return
        }
        var options = try position.values()
        if action != .add {
            guard let attachment else { throw ValidationError("--attachment is required") }
            options["attachment"] = attachment
        }
        if action == .add || action == .replace {
            guard let file else { throw ValidationError("--file is required") }
            options["file"] = URL(fileURLWithPath: file).standardizedFileURL.path
        }
        if action == .mv {
            guard let to else { throw ValidationError("--to is required") }
            options["target"] = to
        }
        if action == .view {
            guard let size, (0...2).contains(size) else { throw ValidationError("--size must be 0, 1 or 2") }
            options["size"] = size
        }
        let operation = action == .rm ? "remove" : action == .mv ? "move" : action.rawValue
        try output.writeAction("attachments " + action.rawValue, store.editNote(note.id, operation: "attachment-" + operation, options: options), text: note.id)
    }

    func exportFiles(_ items: [[String: Any]]) throws -> [[String: String]] {
        guard (file != nil) != (directory != nil), file == nil || attachment != nil else {
            throw ValidationError("export requires --directory or both --attachment and --file")
        }
        let selected = items.filter { attachment == nil ? $0["type"] as? String != "com.apple.notes.table" : $0["id"] as? String == attachment }
        guard attachment == nil || selected.count == 1 else { throw ValidationError("attachment not found in this note") }
        var copies: [(URL, URL, String)] = []
        var names = Set<String>()
        for item in selected {
            guard let id = item["id"] as? String, let path = item["path"] as? String, item["available"] as? Bool == true else {
                throw ValidationError("attachment file is not available locally")
            }
            let source = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: source.path) else { throw ValidationError("attachment file is not available locally") }
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
                throw ValidationError("destination already exists: \(destination.path)")
            }
            copies.append((source, destination, id))
        }
        if let directory, !copies.isEmpty {
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: directory), withIntermediateDirectories: true)
        }
        var exported: [[String: String]] = []
        for (source, destination, id) in copies {
            try FileManager.default.copyItem(at: source, to: destination)
            exported.append(["attachment": id, "path": destination.path])
        }
        return exported
    }
}

struct Links: ParsableCommand {
    @OptionGroup var output: OutputOptions
    enum Action: String, ExpressibleByArgument { case ls, add, rm }
    static let configuration = CommandConfiguration(abstract: "Create, list and remove native cross-references between notes", discussion: """
        Links are one-way. Get link ids with ls.
        rm removes the link, not the target note.

        EXAMPLES
          nb links add <source-id> --to <target-id>
          nb links ls <source-id>
          nb links rm <source-id> --link <link-id>
        """)
    @Argument(help: "ls, add or rm") var action: Action
    @OptionGroup var note: LocalNoteOptions
    @OptionGroup var position: PositionOptions
    @Option(help: "Target note id for add") var to: String?
    @Option(help: "Link id from links ls, required for rm") var link: String?

    func validate() throws {
        guard to == nil || action == .add else { throw ValidationError("--to is only valid for links add") }
        guard link == nil || action == .rm else { throw ValidationError("--link is only valid for links rm") }
        guard (position.before == nil && position.after == nil) || action == .add else {
            throw ValidationError("--before/--after is only valid for links add")
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
        if action == .ls { return try output.write(["links": store.readNote(note.id)["links"]!]) }
        try output.writeAction("links " + action.rawValue, store.editNote(note.id, operation: action == .add ? "link-add" : "link-remove", options: options), text: note.id)
    }
}

struct Search: ParsableCommand {
    @OptionGroup var output: OutputOptions
    enum Field: String, ExpressibleByArgument { case all, id, title, text, attachment, tag, link, document }
    static let configuration = CommandConfiguration(abstract: "Find notes by text, title, id, table cells, tags, links or attachment filename", discussion: """
        Prints only note URLs, one per line. No matches produce no stdout.
        Fuzzy matching is enabled by default. Exact matches rank first.
        all searches document contents automatically, including PDF text and image text.
        Add --json for titles, excerpts and match details. Locked and deleted notes are excluded.

        EXAMPLES
          nb search invoice
          nb search "Invoice number" --field document
          nb search project --field tag --json
        """)
    @Argument(help: "Nonempty text or id fragment to find") var query: String
    @Option(help: "all, id, title, text, attachment, tag, link or document") var field: Field = .all
    @Option(help: "Exact folder name or local folder id") var folder: String?
    @Option(help: "Maximum number of results") var limit = 50
    @Option(help: "Skip this many results") var offset = 0

    func run() throws {
        guard limit > 0 && offset >= 0 else { throw ValidationError("--limit must be positive and --offset nonnegative") }
        var options: [String: Any] = ["field": field.rawValue, "limit": limit, "offset": offset]
        if let folder { options["folder"] = folder }
        let result = try openLocalNotes(readOnly: true).search(query, options: options)
        guard let notes = result["notes"] as? [[String: Any]] else { throw NotesError(description: "Notes returned invalid search results") }
        let ids = try notes.map { note in
            guard let id = note["id"] as? String else { throw NotesError(description: "Notes returned a search result without an id") }
            return id
        }
        if let errors = result["documentErrors"] as? [[String: String]] {
            for error in errors {
                guard let attachment = error["attachment"], let message = error["error"] else { throw NotesError(description: "Notes returned invalid document diagnostics") }
                FileHandle.standardError.write(Data("Document error: \(attachment) \(message)\n".utf8))
            }
        }
        try output.write(result, text: ids.joined(separator: "\n"))
        guard let total = result["total"] as? Int else { throw NotesError(description: "Notes returned invalid search count") }
        output.summary("\(ids.count) of \(total) notes")
    }
}
