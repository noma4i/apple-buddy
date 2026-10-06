import ArgumentParser
import Foundation

struct MakeFolder: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "mkfolder",
        abstract: "Create a folder and print its id",
        discussion: """
        Creates a folder in the sole Notes account, or within --parent. Names must be unique among siblings.
        Saves locally, run nb sync after the last write to send changes to iCloud.

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
        abstract: "Delete an empty folder, or every empty folder of a subtree",
        discussion: """
        Refuses to delete a folder that still has notes. Remove them with `rm` or move them with `mv` first.
        With --empty deletes every folder of the subtree that has no notes and no remaining subfolders,
        deepest first, including the folder itself when it ends up empty. Folders with notes stay.
        --empty prints the UUIDs of the deleted folders. With --json returns {action, saved, folders}.
        Saves locally, run nb sync after the last write to send changes to iCloud.

        EXAMPLES
          nb rmfolder Work
          nb rmfolder Archive --empty
        """
    )

    @Argument(help: ArgumentHelp("Folder to delete, by \(ReferenceHelp.folder)")) var name: String
    @Flag(help: "Delete every empty folder of the subtree instead of only this folder") var empty = false

    func run() throws {
        let folder = try resolveFolder(named: name)
        if empty {
            let removed = try openLocalNotes(readOnly: false).removeEmptyFolders(folder.id)
            return try output.writeBatch("rmfolder", items: removed, key: "folders", summary: "rmfolder: \(removed.count) empty folders under \(folder.path)")
        }
        guard let id = try openLocalNotes(readOnly: true).publicIdentifiers(forIDs: [folder.id])[folder.id] else { throw NotesError(description: "Folder has no UUID") }
        try openLocalNotes(readOnly: false).removeFolder(folder.id)
        try output.writeAction("rmfolder", ["id": id, "path": folder.path, "noteCount": folder.noteCount, "subfolderCount": folder.subfolderCount, "deleted": true])
    }
}

struct MoveFolder: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "mvfolder",
        abstract: "Move a folder under another folder or to the top level",
        discussion: """
        Moves the folder with all its notes and subfolders. The folder id stays the same.
        A folder cannot move into itself. The name must stay unique among its new siblings.
        Saves locally, run nb sync after the last write to send changes to iCloud.

        EXAMPLES
          nb mvfolder Work/Old --parent Archive
          nb mvfolder Archive/Old --root
        """
    )

    @Argument(help: ArgumentHelp("Folder to move, by \(ReferenceHelp.folder)")) var name: String
    @Option(help: ArgumentHelp("New parent folder, by \(ReferenceHelp.folder)")) var parent: String?
    @Flag(help: "Move to the top level instead of under --parent") var root = false

    func run() throws {
        guard (parent == nil) != !root else { throw ValidationError("choose either --parent or --root") }
        let folder = try resolveFolder(named: name)
        let target = try parent.map(resolveFolder(named:))
        try openLocalNotes(readOnly: false).moveFolder(folder.id, toParent: target?.id)
        guard var data = try openLocalNotes(readOnly: true).listFolders().first(where: { $0["id"] as? String == folder.id }) else { throw NotesError(description: "Moved folder cannot be read") }
        data["moved"] = true
        try output.writeAction("mvfolder", data)
    }
}

struct RenameFolder: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "renamefolder",
        abstract: "Rename a folder",
        discussion: """
        Changes the folder name. The folder id, notes and subfolders stay the same.
        The new name must be unique among the siblings.
        Saves locally, run nb sync after the last write to send changes to iCloud.

        EXAMPLE
          nb renamefolder Work/Old --name "Old projects"
        """
    )

    @Argument(help: ArgumentHelp("Folder to rename, by \(ReferenceHelp.folder)")) var name: String
    @Option(name: .customLong("name"), help: "New folder name") var newName: String

    func run() throws {
        let folder = try resolveFolder(named: name)
        try openLocalNotes(readOnly: false).renameFolder(folder.id, to: newName)
        guard var data = try openLocalNotes(readOnly: true).listFolders().first(where: { $0["id"] as? String == folder.id }) else { throw NotesError(description: "Renamed folder cannot be read") }
        data["renamed"] = true
        try output.writeAction("renamefolder", data)
    }
}
