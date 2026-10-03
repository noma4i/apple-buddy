import ArgumentParser
import Foundation

struct MakeFolder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mkfolder",
        abstract: "Create a folder and print its id",
        discussion: """
        Creates a folder in the sole Notes account, or within --parent. Names must be unique among siblings.

        EXAMPLE
          notes-buddy mkfolder Work
        """
    )

    @Argument(help: "Name of the new folder") var name: String
    @Option(help: "Parent folder name or id") var parent: String?

    func run() throws {
        print(try openLocalNotes(readOnly: false).createFolder(name, parent: parent))
    }
}

struct RemoveFolder: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rmfolder",
        abstract: "Delete an empty folder",
        discussion: """
        Refuses to delete a folder that still has notes. Remove them with `rm` or move them with `mv` first.

        EXAMPLE
          notes-buddy rmfolder Work
        """
    )

    @Argument(help: "Name of the folder to delete") var name: String

    func run() throws {
        try openLocalNotes(readOnly: false).removeFolder(name)
    }
}
