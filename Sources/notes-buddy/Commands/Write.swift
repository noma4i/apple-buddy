import ArgumentParser
import Foundation

struct New: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create a note and print its id",
        discussion: """
        Creates the note in an existing folder (see `mkfolder`) and prints its id.
        --title adds a heading above the body. The body comes from an HTML file, or from stdin with `-`.
        Without --html the note has only the title.

        EXAMPLES
          notes-buddy new --folder Work --title "Plan" --html body.html
          echo '<p>Buy <b>milk</b></p>' | notes-buddy new --folder Home --title "Shopping" --html -
        """
    )

    @Option(help: "Folder name, must exist") var folder: String
    @Option(help: "Title, placed above the body as a heading") var title: String?
    @Option(help: "HTML body file, - for stdin") var html: String?

    func run() throws {
        let heading = title.map { "<h1>\(escapeHTML($0))</h1>" } ?? ""
        let body = heading + (try readHTML(from: html))
        print(try openLocalNotes(readOnly: false).createNote(inFolder: folder, html: body))
    }
}

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Delete a note (moves it to Recently Deleted)",
        discussion: """
        The note goes to Recently Deleted in Notes and can be restored there.

        EXAMPLE
          notes-buddy rm <id>
        """
    )

    @Argument(help: "Note id from `ls` or `new`") var id: String

    func run() throws {
        try openLocalNotes(readOnly: false).deleteNote(id)
    }
}

struct Move: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mv",
        abstract: "Move a note to another folder",
        discussion: """
        Moves the note to an existing folder. The note id stays the same.

        EXAMPLE
          notes-buddy mv <id> --folder Archive
        """
    )

    @Argument(help: "Note id from `ls` or `new`") var id: String
    @Option(help: "Target folder name") var folder: String

    func run() throws {
        try openLocalNotes(readOnly: false).moveNote(id, toFolder: folder)
    }
}

struct Append: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Add HTML to the end of a note without attachments",
        discussion: """
        Reads the current HTML body, adds your HTML at the end and writes the body back.
        Refuses on attachments, links, tags, checklists and shared notes. Prefer insert for native text edits.

        EXAMPLE
          echo '<p>Done</p>' | notes-buddy append <id> --html -
        """
    )

    @Argument(help: "Note id from `ls` or `new`") var id: String
    @Option(help: "HTML file, - for stdin") var html: String

    func run() throws {
        try setNoteBody(id: id, html: try noteBody(id: id) + readHTML(from: html))
    }
}

struct Replace: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Replace a fragment of the HTML body in a note without attachments",
        discussion: """
        Finds a text fragment in the HTML body (see `show --html`) and replaces it. The rest of the note stays as it is.
        Fails if the fragment is missing, or occurs more than once unless --all is set.
        Refuses on attachments, links, tags, checklists and shared notes. Prefer edit for native text edits.

        EXAMPLES
          notes-buddy replace <id> --find "OLD" --with "NEW"
          notes-buddy replace <id> --find "<b>draft</b>" --with "<i>final</i>"
        """
    )

    @Argument(help: "Note id from `ls` or `new`") var id: String
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
    }
}

struct Attach: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Attach a file to a note",
        discussion: """
        Adds the file to the end of the note, for example a PDF. Notes shows it inline.
        Works on notes that already have attachments, and does not change the text.
        Prints "attached <name>" after saving. Notes quits automatically before writing.

        EXAMPLE
          notes-buddy attach <id> report.pdf
        """
    )

    @Argument(help: "Note id from `ls` or `new`") var id: String
    @Argument(help: "Path of the file to attach") var file: String

    func run() throws {
        let url = URL(fileURLWithPath: file).standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw NotesError(description: "file not readable: \(url.path)")
        }
        _ = try openLocalNotes(readOnly: false)
            .editNote(id, operation: "attachment-add", options: ["file": url.path])
        print("attached \(url.lastPathComponent)")
    }
}
