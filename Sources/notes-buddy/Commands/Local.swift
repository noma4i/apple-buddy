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

func printDictionary(_ value: [AnyHashable: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read native text, formatting, attachments, tags, links and tables as JSON", discussion: "Reads this computer's Notes database without changing it. Objects appear in text as U+FFFC. Use returned ids for attachments and links. Example: notes-buddy inspect <id>")
    @OptionGroup var note: LocalNoteOptions

    func run() throws {
        try printDictionary(note.open(readOnly: true).readNote(note.id))
    }
}

struct Edit: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Replace visible text while preserving attachments and formatting", discussion: "Matches literal visible text, not HTML. Missing or ambiguous matches fail without saving. Use --all for every match. Cannot match across object markers. Example: notes-buddy edit <id> --find draft --with final")
    @OptionGroup var note: LocalNoteOptions
    @Option(help: "Exact visible text to find") var find: String
    @Option(name: .customLong("with"), help: "Replacement text") var replacement: String
    @Flag(help: "Replace all occurrences") var all = false

    func run() throws {
        let store = try note.open(readOnly: false)
        try printDictionary(store.editNote(note.id, operation: "replace", options: ["find": find, "replacement": replacement, "all": all]))
    }
}

struct Insert: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Insert visible text at an anchor, or append it", discussion: "Without an anchor, appends plain text. --before and --after require one exact match and cannot be combined. Example: notes-buddy insert <id> --text 'See also: ' --after Summary")
    @OptionGroup var note: LocalNoteOptions
    @OptionGroup var position: PositionOptions
    @Option(help: "Text to insert") var text: String

    func run() throws {
        var options = try position.values()
        options["text"] = text
        try printDictionary(note.open(readOnly: false).editNote(note.id, operation: "insert", options: options))
    }
}

struct Format: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Format selected text or its paragraphs, including checklists", discussion: "Inline styles affect selected text. Paragraph styles affect each selected paragraph. --off removes an inline style. --style body removes lists or headings. Checklist items are unchecked unless --checked is set. Example: notes-buddy format <id> --find 'Buy milk' --style checklist --checked")
    @OptionGroup var note: LocalNoteOptions
    @Option(help: "Exact visible text to select") var find: String
    @Option(help: "bold, italic, underline, strikethrough, title, heading, subheading, body, monospace, bullet, numbered, checklist") var style: String
    @Flag(help: "Remove the selected inline style") var off = false
    @Flag(help: "Check checklist items") var checked = false
    @Flag(help: "Format all occurrences") var all = false

    func run() throws {
        try printDictionary(note.open(readOnly: false).editNote(note.id, operation: "format", options: ["find": find, "style": style, "off": off, "checked": checked, "all": all]))
    }
}

struct Tags: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List, add or remove native tags on a note", discussion: "Without options, prints tags as JSON. Separate names with slashes, commas or whitespace. Each name becomes a distinct native tag, not text. Duplicates are ignored. Invalid names reject the whole batch. --remove uses the same separators and affects only this note. Search with ls --tag. Example: notes-buddy tags <id> --add 'invoices/tech,other'")
    @OptionGroup var note: LocalNoteOptions
    @Option(help: "Native tags to add, separated by slash, comma or whitespace") var add: String?
    @Option(help: "Native tags to remove, separated by slash, comma or whitespace") var remove: String?

    func run() throws {
        guard add == nil || remove == nil else { throw ValidationError("choose either --add or --remove") }
        let store = try note.open(readOnly: add == nil && remove == nil)
        if let add { return try printDictionary(store.editNote(note.id, operation: "tag-add", options: ["name": add])) }
        if let remove { return try printDictionary(store.editNote(note.id, operation: "tag-remove", options: ["name": remove])) }
        try printDictionary(["tags": store.readNote(note.id)["tags"]!])
    }
}

struct Attachments: ParsableCommand {
    enum Action: String, ExpressibleByArgument { case ls, export, add, rm, replace, mv, view }
    static let configuration = CommandConfiguration(abstract: "List, export, add, remove, replace, move or resize note attachments", discussion: """
        Ids come from inspect or attachments ls. Output is JSON, except export prints the destination path.
        export copies a local file and refuses an existing destination. It does not download iCloud files.
        add inserts a file at --before, --after, or the end. rm removes the object, not the original input file.
        replace swaps the file at its existing position. mv moves it to --to within the same account.
        view writes size 0, 1 or 2. The visual effect depends on the file type.
        Writes automatically quit Notes normally. Export before rm if you need a copy.

        EXAMPLES
          notes-buddy attachments ls <id>
          notes-buddy attachments add <id> --file report.pdf --after Summary
          notes-buddy attachments export <id> --attachment <attachment-id> --file saved.pdf
          notes-buddy attachments replace <id> --attachment <attachment-id> --file updated.pdf
          notes-buddy attachments mv <id> --attachment <attachment-id> --to <target-id>
          notes-buddy attachments view <id> --attachment <attachment-id> --size 1
          notes-buddy attachments rm <id> --attachment <attachment-id>
        """)
    @Argument(help: "ls, export, add, rm, replace, mv, view") var action: Action
    @OptionGroup var note: LocalNoteOptions
    @OptionGroup var position: PositionOptions
    @Option(help: "Attachment id from inspect or attachments ls") var attachment: String?
    @Option(help: "Input file for add or replace, output file for export") var file: String?
    @Option(help: "Destination note id for mv") var to: String?
    @Option(help: "Notes view size: 0 (default), 1 or 2") var size: Int?

    func run() throws {
        let store = try note.open(readOnly: action == .ls || action == .export)
        if action == .ls { return try printDictionary(["attachments": store.readNote(note.id)["attachments"]!]) }
        if action == .export {
            guard let attachment, let file else { throw ValidationError("export requires --attachment and --file") }
            let items = try store.readNote(note.id)["attachments"] as? [[String: Any]]
            guard let item = items?.first(where: { $0["id"] as? String == attachment }),
                  let path = item["path"] as? String, item["available"] as? Bool == true else {
                throw ValidationError("attachment file is not available locally")
            }
            let destination = URL(fileURLWithPath: file)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: destination)
            print(destination.path)
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
        try printDictionary(store.editNote(note.id, operation: "attachment-" + operation, options: options))
    }
}

struct Links: ParsableCommand {
    enum Action: String, ExpressibleByArgument { case ls, add, rm }
    static let configuration = CommandConfiguration(abstract: "Create, list and remove native cross-references between notes", discussion: """
        Creates a native Notes link using the target note's title. The target must exist in this database.
        ls prints link ids and target note ids. A missing target means the target is unavailable.
        add inserts at --before, --after, or the end. rm removes only the link, never the target note.
        Links are one-way. For links both ways, run add once from each note. Output is JSON.

        EXAMPLES
          notes-buddy links add <source-id> --to <target-id> --after Summary
          notes-buddy links ls <source-id>
          notes-buddy links rm <source-id> --link <link-id>
        """)
    @Argument(help: "ls, add or rm") var action: Action
    @OptionGroup var note: LocalNoteOptions
    @OptionGroup var position: PositionOptions
    @Option(help: "Target note id for add") var to: String?
    @Option(help: "Link id from links ls, required for rm") var link: String?

    func run() throws {
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
        if action == .ls { return try printDictionary(["links": store.readNote(note.id)["links"]!]) }
        try printDictionary(store.editNote(note.id, operation: action == .add ? "link-add" : "link-remove", options: options))
    }
}

struct Search: ParsableCommand {
    enum Field: String, ExpressibleByArgument { case all, id, title, text, attachment, tag, link, document }
    static let configuration = CommandConfiguration(abstract: "Find notes by text, title, id, table cells, tags, links or attachment filename", discussion: """
        Searches this computer's Notes database without launching Notes. Prints JSON.
        Partial phrases ignore case, accents and whitespace differences. The default field is all.
        Fuzzy matching is enabled by default. Each alphabetic word of 4 or more letters allows one insertion, deletion, substitution or adjacent transposition.
        Three-letter words allow adjacent transpositions only. Numbers, punctuation and ids stay literal.
        Exact matches rank before fuzzy matches. Within each group, newest notes come first.
        text includes table cells. attachment searches filenames. all includes existing Notes document indexes.
        document reads local PDFs and recognizes images and scanned PDF pages through Apple Vision.
        all searches document contents automatically. Exact existing index matches avoid repeated extraction.
        No network access or database writes occur.
        JSON reports scannedDocuments, unavailableDocuments and documentErrors. OCR can be slow.
        id accepts a complete or partial local note id. tag searches native tag names.
        link searches native link labels. --folder accepts an exact folder name or local folder id.
        Deleted notes are excluded. Locked notes are skipped and counted in skippedProtected.
        Results contain id, title, folder, matchedFields, excerpt and matchType (exact or fuzzy).
        total is the count before pagination. Use --offset and --limit for more results.

        EXAMPLES
          notes-buddy search invoice
          notes-buddy search report.pdf --field attachment
          notes-buddy search "Invoice number" --field document --folder invoices
          notes-buddy search p123 --field id
          notes-buddy search project --field tag --folder Work
          notes-buddy search budget --field text --limit 20 --offset 20
          notes-buddy inspect <id-from-search>
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
        try printDictionary(openLocalNotes(readOnly: true).search(query, options: options))
    }
}
