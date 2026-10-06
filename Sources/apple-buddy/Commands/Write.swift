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
        Saves locally, run abdy notes sync after the last write to send changes to iCloud.

        EXAMPLES
          abdy notes new --folder Work --title "Plan" --html body.html
          echo '<p>Buy <b>milk</b></p>' | abdy notes new --folder Home --title "Shopping" --html -
        """
    )

    @Option(help: ArgumentHelp("Existing folder, by \(ReferenceHelp.folder)")) var folder: String
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
        The notes go to Recently Deleted in Notes and can be restored there.
        Accepts many ids, or - to read ids from stdin, 1 per line. All are checked before any change, 1 refusal cancels the batch.
        Prints the UUIDs of the removed notes. With --json returns {action, saved, notes}.
        Saves locally, run abdy notes sync after the last write to send changes to iCloud.

        EXAMPLES
          abdy notes rm <id>
          abdy notes search draft --field title | abdy notes rm -
        """
    )

    @Argument(help: ArgumentHelp("1 or more notes, by \(ReferenceHelp.note), or - for ids from stdin")) var ids: [String]

    func run() throws {
        let notes = try openLocalNotes(readOnly: false).trashNotes(withIDs: try noteReferences(ids))
        try output.writeBatch("rm", items: notes, key: "notes", summary: "rm: \(notes.count) notes to Recently Deleted")
    }
}

struct Move: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "mv",
        abstract: "Move a note to another folder",
        discussion: """
        Moves the notes to an existing folder. Note ids stay the same.
        Accepts many ids, or - to read ids from stdin, 1 per line. All are checked before any change, 1 refusal cancels the batch.
        Prints the UUIDs of the moved notes. With --json returns {action, saved, folder, folderPath, notes}.
        Saves locally, run abdy notes sync after the last write to send changes to iCloud.

        EXAMPLES
          abdy notes mv <id> --folder Archive
          abdy notes ls --folder Inbox | abdy notes mv - --folder Archive
        """
    )

    @Argument(help: ArgumentHelp("1 or more notes, by \(ReferenceHelp.note), or - for ids from stdin")) var ids: [String]
    @Option(help: ArgumentHelp("Target folder, by \(ReferenceHelp.folder)")) var folder: String

    func run() throws {
        let target = try resolveFolder(named: folder)
        let notes = try openLocalNotes(readOnly: false).moveNotes(withIDs: try noteReferences(ids), toFolder: target.id)
        try output.writeBatch("mv", items: notes, key: "notes", fields: ["folder": target.id, "folderPath": target.path], summary: "mv: \(notes.count) notes to \(target.path)")
    }
}

func writeUntilKeptAfterSync<Result>(_ write: () throws -> Result, synchronize: () throws -> Void, kept: () throws -> Bool) throws -> Result {
    for _ in 1...3 {
        let result = try write()
        try synchronize()
        if try kept() { return result }
        FileHandle.standardError.write(Data("iCloud overwrote this change, writing it again\n".utf8))
    }
    throw NotesError(description: "iCloud overwrote this change 3 times, the note keeps its previous state. Retry later")
}

func setPinned(_ pinned: Bool, id: String) throws -> [AnyHashable: Any] {
    try writeUntilKeptAfterSync({ try autoreleasepool { try openLocalNotes(readOnly: false).editNote(id, operation: pinned ? "pin" : "unpin", options: [:]) } },
        synchronize: { _ = try synchronizeNotes() },
        kept: { try autoreleasepool { try openLocalNotes(readOnly: true).readNote(id)["pinned"] as? Bool == pinned } })
}

struct Pin: ParsableCommand {
    @OptionGroup var output: OutputOptions
    @OptionGroup var note: LocalNoteOptions
    static let configuration = CommandConfiguration(
        abstract: "Pin a note in its folder",
        discussion: "Repeating pin keeps the note pinned. Content stays unchanged. This command syncs on its own and waits for iCloud, the pin state lives there. Example: abdy notes pin <id>"
    )

    func run() throws {
        try output.writeAction("pin", setPinned(true, id: note.id))
    }
}

struct Unpin: ParsableCommand {
    @OptionGroup var output: OutputOptions
    @OptionGroup var note: LocalNoteOptions
    static let configuration = CommandConfiguration(
        abstract: "Unpin a note in its folder",
        discussion: "Repeating unpin keeps the note unpinned. Content stays unchanged. This command syncs on its own and waits for iCloud, the pin state lives there. Example: abdy notes unpin <id>"
    )

    func run() throws {
        try output.writeAction("unpin", setPinned(false, id: note.id))
    }
}

struct Append: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        abstract: "Add HTML to the end of a note without attachments",
        discussion: """
        Reads the current HTML body, adds your HTML at the end and writes the body back.
        Refuses on attachments, links, tags, checklists and shared notes. Prefer insert for native text edits.
        Saves locally, run abdy notes sync after the last write to send changes to iCloud.

        EXAMPLE
          echo '<p>Done</p>' | abdy notes append <id> --html -
        """
    )

    @Argument(help: ReferenceHelp.note) var id: String
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
        Saves locally, run abdy notes sync after the last write to send changes to iCloud.

        EXAMPLES
          abdy notes replace <id> --find "OLD" --with "NEW"
          abdy notes replace <id> --find "<b>draft</b>" --with "<i>final</i>"
        """
    )

    @Argument(help: ReferenceHelp.note) var id: String
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
        Saves locally, run abdy notes sync after the last write to send changes to iCloud.

        EXAMPLE
          abdy notes attach <id> report.pdf
        """
    )

    @Argument(help: ReferenceHelp.note) var id: String
    @Argument(help: "Path of the file to attach") var file: String

    func run() throws {
        let path = try readableFilePath(file)
        _ = try openLocalNotes(readOnly: false)
            .editNote(id, operation: "attachment-add", options: ["file": path])
        try output.writeAction("attach", noteActionData(id: id, fields: ["file": path, "attached": true]))
    }
}
