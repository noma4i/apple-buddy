import ArgumentParser
import Foundation

struct Folders: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        abstract: "List folders",
        discussion: """
        Lists folder UUIDs, paths, note counts and subfolder counts.
        Counts are direct and do not include subfolders. Deleted notes are counted in Recently Deleted.
        With --json includes name, path, parent, noteCount, deletedNoteCount, subfolderCount and empty.

        EXAMPLE
          nb folders --json
        """
    )

    func run() throws {
        let folders = try listFolders()
        try output.writeEncodable(folders, text: folders.map(\.summary).joined(separator: "\n"))
    }
}

struct Stats: ParsableCommand {
    @OptionGroup var output: OutputOptions
    @Option(help: ArgumentHelp("Only this folder and its subfolders, by \(ReferenceHelp.folder)")) var folder: String?
    static let configuration = CommandConfiguration(
        abstract: "Show note counts and folder organization",
        discussion: "Shows active and deleted note counts separately. The first line, totalNoteCount and totalDeletedNoteCount cover every listed folder. Each folder line and noteCount are direct. Empty includes notes and subfolders. Example: nb stats --folder Work --json"
    )

    func run() throws {
        let all = try listFolders()
        var folders = all
        if let folder { folders = foldersWithDescendants(of: try resolveFolder(named: folder), in: all) }
        folders.sort { $0.path < $1.path }
        let notes = folders.reduce(0) { $0 + $1.noteCount }
        let deleted = folders.reduce(0) { $0 + $1.deletedNoteCount }
        let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(folders))
        let text = (["\(notes) notes, \(deleted) deleted notes, \(folders.count) folders"] + folders.map(\.summary)).joined(separator: "\n")
        try output.write(["totalNoteCount": notes, "totalDeletedNoteCount": deleted, "folderCount": folders.count, "folders": values], text: text)
    }
}

struct List: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List notes",
        discussion: """
        Prints one note UUID per line, without titles or other fields.
        With --json prints an array of {id, url, title, folder, folderPath, modified, pinned, protected, tags, attachments, urls}.
        Dates are in ISO 8601. Locked notes have no urls. Newest notes come first.
        --folder includes subfolders. Deleted notes are listed only with --folder "Recently Deleted".
        Without --folder lists the notes of every folder, which is slow with many notes.
        --show prints each note in full, the UUID, title, folder and date, then the show text.
        With --json, --show adds the show fields without runs: text, textLength, tables, links and cloud state.
        --chars N keeps the first N characters of each text, textLength keeps the full length.
        --limit and --offset page the list, stderr reports the returned and total counts.

        EXAMPLES
          nb ls --folder Work
          nb ls --folder Work --show --limit 5
          nb ls --folder Work --show --chars 2000 --json
        """
    )

    @Option(help: ArgumentHelp("Only notes of this folder and its subfolders, by \(ReferenceHelp.folder)")) var folder: String?
    @Option(help: ArgumentHelp("Only notes with exactly this native tag, \(ReferenceHelp.tag)")) var tag: String?
    @OptionGroup var reading: ReadingOptions

    func run() throws {
        var options = try reading.options()
        if let folder { options["folder"] = folder }
        if let tag { options["tag"] = tag }
        let result = try openLocalNotes(readOnly: true).listNotes(options)
        guard let notes = result["notes"] as? [[String: Any]], let total = result["total"] as? Int else { throw NotesError(description: "Notes returned invalid note list") }
        try output.write(notes, text: try reading.render(notes))
        output.summary(reading.limit == nil && reading.offset == 0 ? "\(notes.count) notes" : "\(notes.count) of \(total) notes")
    }
}

struct ReadingOptions: ParsableArguments {
    @Flag(help: "Print each note in full instead of only its UUID") var show = false
    @Option(help: "With --show, keep only the first N characters of each note text") var chars: Int?
    @Option(help: "Maximum number of notes") var limit: Int?
    @Option(help: "Skip this many notes") var offset = 0

    func options() throws -> [String: Any] {
        if let limit, limit <= 0 { throw ValidationError("--limit must be positive") }
        guard offset >= 0 else { throw ValidationError("--offset must be nonnegative") }
        if let chars, chars <= 0 { throw ValidationError("--chars must be positive") }
        if chars != nil && !show { throw ValidationError("--chars needs --show") }
        var options: [String: Any] = ["offset": offset, "show": show]
        if let limit { options["limit"] = limit }
        if let chars { options["chars"] = chars }
        return options
    }

    func render(_ notes: [[String: Any]]) throws -> String {
        guard show else {
            return try notes.map { note in
                guard let id = note["id"] as? String else { throw NotesError(description: "Notes returned a note without an id") }
                return id
            }.joined(separator: "\n")
        }
        return try notes.map { note in
            guard let id = note["id"] as? String, let title = note["title"] as? String, let text = note["text"] as? String,
                  let length = note["textLength"] as? Int else { throw NotesError(description: "Notes returned invalid note data") }
            var lines = [id, "Title: \(title)"]
            if let folder = note["folderPath"] as? String { lines.append("Folder: \(folder)") }
            if let modified = note["modified"] as? String { lines.append("Modified: \(modified)") }
            if let fields = note["matchedFields"] as? [String], let match = note["matchType"] as? String {
                lines.append("Match: \(match) in " + fields.joined(separator: ", "))
            }
            lines.append("")
            lines.append(try renderNote(note))
            if (text as NSString).length < length { lines.append("(first \((text as NSString).length) of \(length) characters)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n---\n")
    }
}

struct Show: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        abstract: "Print a note",
        discussion: """
        Prints the plain text of the note. With --html prints the HTML body,
        the form that `new` and `append` read from a file or from stdin with --html -.
        Text output includes tables, tags, links and attachment access details.
        JSON includes the same native objects as inspect. With --html, JSON also includes html.
        Without --json, --html prints only HTML for use in other commands.

        EXAMPLES
          nb show <id>
          nb show <id> --html
        """
    )

    @Argument(help: ReferenceHelp.note) var id: String
    @Flag(help: "Print the HTML body instead of plain text") var html = false

    func run() throws {
        let store = try openLocalNotes(readOnly: true)
        guard var data = try store.readNote(id) as? [String: Any] else { throw NotesError(description: "Notes returned invalid note data") }
        let content: String
        if html {
            content = try store.html(forNote: id)
            data["html"] = content
        } else { content = try renderNote(data) }
        try output.write(data, text: content)
    }
}

func renderNote(_ data: [String: Any]) throws -> String {
    guard let text = data["text"] as? String, let attachments = data["attachments"] as? [[String: Any]],
          let tables = data["tables"] as? [[[String]]], let tags = data["tags"] as? [[String: Any]],
          let links = data["links"] as? [[String: Any]] else { throw NotesError(description: "Notes returned invalid note objects") }
    var sections = [text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .newlines)]
    for (index, table) in tables.enumerated() {
        sections.append("Table \(index + 1):\n" + table.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
    }
    if !tags.isEmpty { sections.append("Tags: " + tags.compactMap { $0["name"] as? String }.joined(separator: ", ")) }
    if !links.isEmpty { sections.append("Links:\n" + links.map { "  \($0["name"] ?? "")\n  \($0["target"] ?? $0["id"] ?? "")" }.joined(separator: "\n")) }
    if let urls = data["urls"] as? [[String: Any]], !urls.isEmpty {
        sections.append("Web links:\n" + urls.map { "  \($0["name"] ?? "")\n  \($0["url"] ?? "")" }.joined(separator: "\n"))
    }
    if !attachments.isEmpty {
        var lines = ["Attachments:"]
        for item in attachments {
            guard let id = item["id"] as? String, let type = item["type"] as? String else { throw NotesError(description: "Notes returned invalid attachment data") }
            let name = item["name"] as? String ?? ""
            lines.append("  \(name.isEmpty ? type : name)\n    \(id)")
            if item["kind"] as? String == "table" { lines.append("    Native table, shown above") }
            else if item["exportable"] as? Bool == true, let path = item["path"] as? String { lines.append("    File: \(path)") }
            else { lines.append("    File not available locally") }
        }
        if attachments.contains(where: { $0["exportable"] as? Bool == true }), let id = data["id"] as? String {
            lines.append("  Export: nb attachments export '\(id)' --directory ./attachments")
        }
        sections.append(lines.joined(separator: "\n"))
    }
    return sections.joined(separator: "\n\n")
}
