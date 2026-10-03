import ArgumentParser
import Foundation
import NotesNative

@main
struct NotesBuddy: ParsableCommand {
    static func main() {
        var failure: Error?
        do {
            var command = try parseAsRoot()
            try autoreleasepool { try command.run() }
        } catch { failure = error }
        if NBCommittedLiveWrites() > 0 {
            do { _ = try synchronizeNotes() }
            catch { if failure == nil { failure = error } else { FileHandle.standardError.write(Data("Sync request failed: \(error)\n".utf8)) } }
        }
        if let failure { exit(withError: failure) }
    }
    static let configuration = CommandConfiguration(
        commandName: "notes-buddy",
        abstract: "Create, edit and organize Apple Notes from the terminal",
        discussion: """
        Uses the Notes data of the macOS user running this command, on this computer.
        No separate login, account configuration, UI scripting or Shortcuts.
        All commands use the installed private Notes APIs and Core Data.
        The private Notes API was tested on macOS 27.0.1, not other versions.

        NOTE IDS
          Every note has an id like x-coredata://.../ICNote/p123.
          Get it from `ls` or `new`. Ids belong to this computer's database.
          Folders accept names or ids. Duplicate names require ids.
          mkfolder --parent creates a nested folder.

        NOTE BODY
          new accepts HTML: <h1>, <p>, <b>, <i>, <ul>, <li>, <table>.
          show --html exports HTML. Native edit and insert accept plain text.
          Notes uses the first line as the title.

        NATIVE EDITS
          search finds notes by content, title, id, tags and attachment filenames.
          Fuzzy matching and PDF/image text search are enabled by default, without extra flags.
          Exact matches rank first. Phrases match across whitespace and line breaks.
          inspect reads text, formatting and object ids as JSON.
          edit and insert change visible text without rewriting the HTML body.
          format edits styles and checklists. table edits native tables.
          attachments lists, exports, adds, replaces, moves and removes files.
          tags manages native tags. ls --tag finds tagged notes.
          links creates and removes cross-references to other notes.

        SAFETY
          Native writes automatically quit Notes normally. Read-only commands leave it running.
          After saved writes, Notes starts background-only, without windows or a Dock icon.
          Sync quits Notes after waiting, including on error.
          Every write waits for iCloud acknowledgement, without extra flags.
          A 120-second sync timeout exits nonzero. Local changes remain saved.
          sync --status reads acknowledgement counters. sync waits for an empty queue.
          Do not open Notes during a write. Protected, shared and deleted notes
          cannot be edited natively. Concurrent database conflicts are rejected.
          append and replace edit HTML, unlike insert and edit. They refuse
          objects and checklists that an HTML rewrite would lose.
          Keep a backup. snapshot-db copies records, not attachment files.
          Never restore a database copy over live iCloud data.

        PERMISSIONS
          Database access may require Full Disk Access for the calling application.

        OUTPUT
          Native commands print JSON. table ls uses TSV unless --json is passed.
          new prints a note id. export prints a file path. Errors exit nonzero.
          Help does not open Notes or its database.

        EXAMPLES
          notes-buddy mkfolder Work
          notes-buddy new --folder Work --title "Plan" --html body.html
          notes-buddy ls --folder Work
          notes-buddy edit <id> --find draft --with final
          notes-buddy attach <id> report.pdf
          notes-buddy links add <id> --to <other-id>
          notes-buddy rm <id>

        Run `notes-buddy help <command>` for details about one command.
        """,
        subcommands: [Folders.self, MakeFolder.self, RemoveFolder.self, List.self, Show.self, Search.self, New.self, Remove.self, Move.self, Append.self, Replace.self, Attach.self, Tables.self, SnapshotDatabase.self, Inspect.self, Edit.self, Insert.self, Format.self, Tags.self, Links.self, Attachments.self, ImportBear.self, Sync.self]
    )
}
