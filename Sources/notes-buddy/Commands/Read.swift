import ArgumentParser

struct Folders: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List folders",
        discussion: """
        Prints one folder per line: id, then name, separated by a tab.
        With --json prints an array of {id, name}.

        EXAMPLE
          notes-buddy folders --json
        """
    )

    @Flag(help: "Print JSON instead of text") var json = false

    func run() throws {
        let folders = try listFolders()
        if json { return try printJSON(folders) }
        folders.forEach { print("\($0.id)\t\($0.name)") }
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List notes",
        discussion: """
        Prints one note per line: id, folder, title, separated by tabs.
        With --json prints an array of {id, title, folder, modified}, dates in ISO 8601.
        Without --folder lists the notes of every folder, which is slow with many notes.

        EXAMPLES
          notes-buddy ls --folder Work
          notes-buddy ls --json
        """
    )

    @Option(help: "Only notes of this folder (by name)") var folder: String?
    @Option(help: "Only notes with this native tag") var tag: String?
    @Flag(help: "Print JSON instead of text") var json = false

    func run() throws {
        let folders = try folder.map { [try resolveFolder(named: $0)] } ?? listFolders()
        var notes = try folders.flatMap(listNotes(in:))
        if let tag {
            let matching = Set(try openLocalNotes(readOnly: true).noteIDs(withTag: tag))
            notes = notes.filter { matching.contains($0.id) }
        }
        if json { return try printJSON(notes) }
        notes.forEach { print("\($0.id)\t\($0.folder)\t\($0.title)") }
    }
}

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print a note",
        discussion: """
        Prints the plain text of the note. With --html prints the HTML body,
        which is the form that `new`, `append` and `replace` accept.
        Attachments are shown as a placeholder character in plain text and are not printed in HTML.

        EXAMPLES
          notes-buddy show <id>
          notes-buddy show <id> --html
        """
    )

    @Argument(help: "Note id from `ls` or `new`") var id: String
    @Flag(help: "Print the HTML body instead of plain text") var html = false

    func run() throws {
        if html { return print(try noteBody(id: id)) }
        guard let text = try openLocalNotes(readOnly: true).readNote(id)["text"] as? String else { throw NotesError(description: "Notes returned invalid text") }
        print(text)
    }
}
