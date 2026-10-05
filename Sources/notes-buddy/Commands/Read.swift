import ArgumentParser
import Foundation

struct Folders: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        abstract: "List folders",
        discussion: """
        Lists folder UUIDs, paths, note counts and subfolder counts.
        With --json includes noteCount, deletedNoteCount, subfolderCount and empty.

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
    @Option(help: "Folder name, UUID or unique prefix, include its descendants") var folder: String?
    static let configuration = CommandConfiguration(
        abstract: "Show note counts and folder organization",
        discussion: "Shows active and deleted note counts separately. Folder counts are direct, not recursive. Empty includes notes and subfolders. Example: nb stats --folder Work --json"
    )

    func run() throws {
        let all = try listFolders()
        var folders = all
        if let folder {
            let root = try resolveFolder(named: folder)
            var included: Set<String> = [root.id]
            var changed = true
            while changed {
                let previous = included.count
                for candidate in all where candidate.parent.map(included.contains) == true { included.insert(candidate.id) }
                changed = included.count != previous
            }
            folders = all.filter { included.contains($0.id) }
        }
        folders.sort { $0.path < $1.path }
        let notes = folders.reduce(0) { $0 + $1.noteCount }
        let deleted = folders.reduce(0) { $0 + $1.deletedNoteCount }
        let values = try JSONSerialization.jsonObject(with: JSONEncoder().encode(folders))
        let text = (["\(notes) notes, \(deleted) deleted notes, \(folders.count) folders"] + folders.map(\.summary)).joined(separator: "\n")
        try output.write(["noteCount": notes, "deletedNoteCount": deleted, "folderCount": folders.count, "folders": values], text: text)
    }
}

struct List: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List notes",
        discussion: """
        Prints one note UUID per line, without titles or other fields.
        With --json prints an array of {id, title, folder, modified}, dates in ISO 8601.
        Without --folder lists the notes of every folder, which is slow with many notes.

        EXAMPLES
          nb ls --folder Work
          nb ls --json
        """
    )

    @Option(help: "Only notes of this folder, by name, UUID or unique prefix") var folder: String?
    @Option(help: "Only notes with this native tag") var tag: String?

    func run() throws {
        let folders = try folder.map { [try resolveFolder(named: $0)] } ?? listFolders()
        var notes = try folders.flatMap(listNotes(in:))
        if let tag {
            let matching = Set(try openLocalNotes(readOnly: true).noteIDs(withTag: tag))
            notes = notes.filter { matching.contains($0.id) }
        }
        try output.writeEncodable(notes, text: notes.map(\.id).joined(separator: "\n"))
        output.summary("\(notes.count) notes")
    }
}

struct Show: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        abstract: "Print a note",
        discussion: """
        Prints the plain text of the note. With --html prints the HTML body,
        which is the form that `new`, `append` and `replace` accept.
        Text output includes tables, tags, links and attachment access details.
        JSON includes the same native objects as inspect. With --html, JSON also includes html.
        Without --json, --html prints only HTML for use in other commands.

        EXAMPLES
          nb show <id>
          nb show <id> --html
        """
    )

    @Argument(help: "Note UUID or unique prefix from ls, search or new") var id: String
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
            guard let id = item["id"] as? String, let type = item["type"] as? String, let name = item["name"] as? String else { throw NotesError(description: "Notes returned invalid attachment data") }
            lines.append("  \(name.isEmpty ? type : name)\n    \(id)")
            if type == "com.apple.notes.table" { lines.append("    Native table, shown above") }
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
