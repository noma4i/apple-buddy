import ArgumentParser
import Foundation
import Darwin
import NotesNative

@main
struct NotesBuddy: ParsableCommand {
    static let releaseVersion = "1.0.0"
    @OptionGroup var output: OutputOptions
    static func main() {
        var commandType: ParsableCommand.Type = Self.self
        let arguments = Array(CommandLine.arguments.dropFirst())
        for (index, argument) in arguments.enumerated() {
            if argument == "--json" && commandType._commandName == configuration.commandName { continue }
            if argument == "help" {
                print(positionalHelp(helpMessage(for: commandType)))
                return
            }
            let isAction = (commandType == Attachments.self && Attachments.Action(rawValue: argument) != nil)
                || (commandType == Links.self && Links.Action(rawValue: argument) != nil)
            if isAction && arguments.dropFirst(index + 1).first == "help" {
                print(positionalHelp(helpMessage(for: commandType)))
                return
            }
            guard let subcommand = commandType.configuration.subcommands.first(where: { $0._commandName == argument }) else { break }
            commandType = subcommand
        }
        var failure: Error?
        do {
            var command = try parseAsRoot()
            try autoreleasepool { try command.run() }
        } catch {
            if exitCode(for: error) == .success { print(positionalHelp(fullMessage(for: error))) }
            else { failure = error }
        }
        if NBCommittedCommandWrites() > synchronizedWrites {
            do { _ = try synchronizeNotes() }
            catch { if failure == nil { failure = error } else { FileHandle.standardError.write(Data("Sync request failed: \(error)\n".utf8)) } }
        }
        if let failure {
            FileHandle.standardError.write(Data((inputErrorMessage(fullMessage(for: failure)) + "\n").utf8))
            Darwin.exit(exitCode(for: failure).rawValue)
        }
    }

    static func inputErrorMessage(_ text: String) -> String {
        positionalHelp(text)
            .replacingOccurrences(of: "Unexpected argument", with: "Unknown command or extra argument")
            .replacingOccurrences(of: "Missing expected argument", with: "Provide the argument")
            .replacingOccurrences(of: "Unknown option", with: "Unsupported option")
    }

    static func positionalHelp(_ text: String) -> String {
        let name = NSRegularExpression.escapedPattern(for: _commandName)
        let formatted = text.replacingOccurrences(of: "(See '\(name)) help([^']*) <subcommand>'", with: "$1$2 <subcommand> help'", options: .regularExpression)
            .replacingOccurrences(of: "(See '\(name)[^']*) --help'", with: "$1 help'", options: .regularExpression)
        guard let usage = formatted.range(of: "(?m)^USAGE: \(name)(?: [a-z][a-z-]*)*", options: .regularExpression) else { return formatted }
        let command = formatted[usage].dropFirst("USAGE: ".count)
        let options = command == _commandName ? formatted : formatted.replacingOccurrences(of: "(?m)^  --version[^\\n]*\\n", with: "", options: .regularExpression)
        return options.replacingOccurrences(of: "(?m)^  -h, --help[^\\n]*", with: "\nHELP: \(command) help", options: .regularExpression)
            .replacingOccurrences(of: "(?m)^OPTIONS:\\n\\n(?=HELP:)", with: "", options: .regularExpression)
    }
    static let configuration = CommandConfiguration(
        commandName: "nb",
        abstract: "Create, edit and organize Apple Notes from the terminal",
        version: releaseVersion,
        subcommands: [Version.self, Folders.self, MakeFolder.self, RemoveFolder.self, List.self, Stats.self, Show.self, OpenNote.self, Search.self, New.self, Remove.self, Move.self, Pin.self, Unpin.self, Append.self, Replace.self, Attach.self, Tables.self, SnapshotDatabase.self, Backup.self, Restore.self, Inspect.self, Edit.self, Insert.self, Format.self, Tags.self, Links.self, Attachments.self, ImportBear.self, Sync.self, MCPCommand.self]
    )
}

struct Version: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        abstract: "Show the installed release version",
        discussion: "Prints the version without reading Notes or starting synchronization. With --json returns name and version. Example: nb version --json"
    )

    func run() throws {
        try output.write(["name": "notes-buddy", "version": NotesBuddy.releaseVersion], text: NotesBuddy.releaseVersion)
    }
}
