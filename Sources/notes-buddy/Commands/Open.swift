import AppKit
import ArgumentParser
import Foundation

struct OpenNote: ParsableCommand {
    @OptionGroup var output: OutputOptions
    @OptionGroup var note: LocalNoteOptions
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a note in Apple Notes",
        discussion: "Opens the selected note in the foreground and leaves Notes running. Does not change the note. Example: nb open <id>"
    )

    func run() throws {
        let store = try note.open(readOnly: true)
        guard var data = try store.noteOpenDetails(note.id) as? [String: Any],
              let address = data["url"] as? String, let url = URL(string: address),
              let id = data["id"] as? String else { throw NotesError(description: "Notes returned no note URL") }
        guard NSWorkspace.shared.open(url) else { throw NotesError(description: "macOS refused to open the note URL") }
        data["action"] = "open"
        data["requested"] = true
        try output.write(data, text: id)
        output.summary("open: \(data["title"] ?? "")")
    }
}
