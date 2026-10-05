import ArgumentParser
import Foundation

struct New: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        abstract: "Create a note and print its id",
        discussion: """
        Creates the note in an existing folder (see `mkfolder`) and prints its id.
        --title adds a heading above the body. The body comes from an HTML file, or from stdin with `-`.
        Without --html the note has only the title.

        EXAMPLES
          nb new --folder Work --title "Plan" --html body.html
          echo '<p>Buy <b>milk</b></p>' | nb new --folder Home --title "Shopping" --html -
        """
    )

    @Option(help: "Existing folder name, UUID or unique prefix") var folder: String
    @Option(help: "Title, placed above the body as a heading") var title: String?
    @Option(help: "HTML body file, - for stdin") var html: String?

    func run() throws {
        let heading = title.map { "<h1>\(escapeHTML($0))</h1>" } ?? ""
        let body = heading + (try readHTML(from: html))
        let id = try openLocalNotes(readOnly: false).createNote(inFolder: folder, html: body)
        try output.writeAction("new", noteActionData(id: id, fields: ["created": true]))
    }
}

struct Remove: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Delete a note (moves it to Recently Deleted)",
        discussion: """
        The note goes to Recently Deleted in Notes and can be restored there.

        EXAMPLE
          nb rm <id>
        """
    )

    @Argument(help: "Note UUID or unique prefix from ls, search or new") var id: String

    func run() throws {
        try openLocalNotes(readOnly: false).deleteNote(id)
        try output.writeAction("rm", noteActionData(id: id, fields: ["deleted": true]))
    }
}

struct Move: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "mv",
        abstract: "Move a note to another folder",
        discussion: """
        Moves the note to an existing folder. The note id stays the same.

        EXAMPLE
          nb mv <id> --folder Archive
        """
    )

    @Argument(help: "Note UUID or unique prefix from ls, search or new") var id: String
    @Option(help: "Target folder name, UUID or unique prefix") var folder: String

    func run() throws {
        try openLocalNotes(readOnly: false).moveNote(id, toFolder: folder)
        try output.writeAction("mv", noteActionData(id: id, fields: ["moved": true]))
    }
}

struct Pin: ParsableCommand {
    @OptionGroup var output: OutputOptions
    @OptionGroup var note: LocalNoteOptions
    static let configuration = CommandConfiguration(
        abstract: "Pin a note in its folder",
        discussion: "Repeating pin keeps the note pinned. Content stays unchanged. Example: nb pin <id>"
    )

    func run() throws {
        try output.writeAction("pin", note.open(readOnly: false).editNote(note.id, operation: "pin", options: [:]))
    }
}

struct Unpin: ParsableCommand {
    @OptionGroup var output: OutputOptions
    @OptionGroup var note: LocalNoteOptions
    static let configuration = CommandConfiguration(
        abstract: "Unpin a note in its folder",
        discussion: "Repeating unpin keeps the note unpinned. Content stays unchanged. Example: nb unpin <id>"
    )

    func run() throws {
        try output.writeAction("unpin", note.open(readOnly: false).editNote(note.id, operation: "unpin", options: [:]))
    }
}

struct Append: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        abstract: "Add HTML to the end of a note without attachments",
        discussion: """
        Reads the current HTML body, adds your HTML at the end and writes the body back.
        Refuses on attachments, links, tags, checklists and shared notes. Prefer insert for native text edits.

        EXAMPLE
          echo '<p>Done</p>' | nb append <id> --html -
        """
    )

    @Argument(help: "Note UUID or unique prefix from ls, search or new") var id: String
    @Option(help: "HTML file, - for stdin") var html: String

    func run() throws {
        try setNoteBody(id: id, html: try noteBody(id: id) + readHTML(from: html))
        try output.writeAction("append", noteActionData(id: id, fields: ["updated": true]))
    }
}

struct Replace: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        abstract: "Replace a fragment of the HTML body in a note without attachments",
        discussion: """
        Finds a text fragment in the HTML body (see `show --html`) and replaces it. The rest of the note stays as it is.
        Fails if the fragment is missing, or occurs more than once unless --all is set.
        Refuses on attachments, links, tags, checklists and shared notes. Prefer edit for native text edits.

        EXAMPLES
          nb replace <id> --find "OLD" --with "NEW"
          nb replace <id> --find "<b>draft</b>" --with "<i>final</i>"
        """
    )

    @Argument(help: "Note UUID or unique prefix from ls, search or new") var id: String
    @Option(help: "Fragment to find, matched against the HTML body") var find: String
    @Option(name: .customLong("with"), help: "Replacement HTML") var replacement: String
    @Flag(help: "Replace every occurrence, otherwise the fragment must occur once") var all = false

    func run() throws {
        guard !find.isEmpty else { throw ValidationError("--find must not be empty") }
        let body = try noteBody(id: id)
        let count = body.components(separatedBy: find).count - 1
        guard count > 0 else { throw NotesError(description: "fragment not found in the HTML body") }
        guard count == 1 || all else { throw NotesError(description: "fragment occurs \(count) times, use --all") }
        try setNoteBody(id: id, html: body.replacingOccurrences(of: find, with: replacement))
        try output.writeAction("replace", noteActionData(id: id, fields: ["updated": true]))
    }
}

struct Attach: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        abstract: "Attach a file to a note",
        discussion: """
        Adds the file to the end of the note, for example a PDF. Notes shows it inline.
        Works on notes that already have attachments, and does not change the text.
        Prints the note UUID after saving. Notes quits automatically before writing.

        EXAMPLE
          nb attach <id> report.pdf
        """
    )

    @Argument(help: "Note UUID or unique prefix from ls, search or new") var id: String
    @Argument(help: "Path of the file to attach") var file: String

    func run() throws {
        let url = URL(fileURLWithPath: file).standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw NotesError(description: "file not readable: \(url.path)")
        }
        _ = try openLocalNotes(readOnly: false)
            .editNote(id, operation: "attachment-add", options: ["file": url.path])
        try output.writeAction("attach", noteActionData(id: id, fields: ["file": url.path, "attached": true]))
    }
}
