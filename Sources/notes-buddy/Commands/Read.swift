import ArgumentParser
import Foundation

struct Folders: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        abstract: "List folders",
        discussion: """
        Lists folder URLs, paths, note counts and subfolder counts.
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
    @Option(help: "Folder name or id, include its descendants") var folder: String?
    static let configuration = CommandConfiguration(
        abstract: "Show note counts and folder organization",
        discussion: "Shows active and deleted note counts separately. Folder counts are direct, not recursive. Empty includes notes and subfolders. Example: nb stats --folder Work --json"
    )

    func run() throws {
        let all = try listFolders()
        var folders = all
        if let folder {
            let matches = all.filter { $0.id == folder || $0.name == folder }
            guard matches.count == 1, let root = matches.first else { throw NotesError(description: "Folder not found or ambiguous, use its id") }
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
        Prints one note URL per line, without titles or other fields.
        With --json prints an array of {id, title, folder, modified}, dates in ISO 8601.
        Without --folder lists the notes of every folder, which is slow with many notes.

        EXAMPLES
          nb ls --folder Work
          nb ls --json
        """
    )

    @Option(help: "Only notes of this folder, by name or id") var folder: String?
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
        Attachments are shown as a placeholder character in plain text and are not printed in HTML.

        EXAMPLES
          nb show <id>
          nb show <id> --html
        """
    )

    @Argument(help: "Note id from `ls` or `new`") var id: String
    @Flag(help: "Print the HTML body instead of plain text") var html = false

    func run() throws {
        let content: String
        if html { content = try noteBody(id: id) }
        else {
            guard let text = try openLocalNotes(readOnly: true).readNote(id)["text"] as? String else { throw NotesError(description: "Notes returned invalid text") }
            content = text
        }
        try output.write(["id": id, html ? "html" : "text": content], text: content)
    }
}
