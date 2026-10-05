import ArgumentParser
import Foundation

struct MakeFolder: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "mkfolder",
        abstract: "Create a folder and print its id",
        discussion: """
        Creates a folder in the sole Notes account, or within --parent. Names must be unique among siblings.

        EXAMPLE
          nb mkfolder Work
        """
    )

    @Argument(help: "Name of the new folder") var name: String
    @Option(help: ArgumentHelp("Parent folder, by \(ReferenceHelp.folder)")) var parent: String?

    func run() throws {
        let id = try openLocalNotes(readOnly: false).createFolder(name, parent: parent)
        guard var data = try openLocalNotes(readOnly: true).listFolders().first(where: { $0["id"] as? String == id }) else { throw NotesError(description: "Created folder cannot be read") }
        data["created"] = true
        try output.writeAction("mkfolder", data)
    }
}

struct RemoveFolder: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "rmfolder",
        abstract: "Delete an empty folder",
        discussion: """
        Refuses to delete a folder that still has notes. Remove them with `rm` or move them with `mv` first.

        EXAMPLE
          nb rmfolder Work
        """
    )

    @Argument(help: ArgumentHelp("Folder to delete, by \(ReferenceHelp.folder)")) var name: String

    func run() throws {
        let folder = try resolveFolder(named: name)
        guard let id = try openLocalNotes(readOnly: true).publicIdentifiers(forIDs: [folder.id])[folder.id] else { throw NotesError(description: "Folder has no UUID") }
        try openLocalNotes(readOnly: false).removeFolder(folder.id)
        try output.writeAction("rmfolder", ["id": id, "path": folder.path, "noteCount": folder.noteCount, "subfolderCount": folder.subfolderCount, "deleted": true])
    }
}
