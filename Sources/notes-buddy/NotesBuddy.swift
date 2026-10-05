import ArgumentParser
import Foundation
import Darwin
import NotesNative

@main
struct NotesBuddy: ParsableCommand {
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
        if NBCommittedCommandWrites() > 0 {
            do { _ = try synchronizeNotes() }
            catch { if failure == nil { failure = error } else { FileHandle.standardError.write(Data("Sync request failed: \(error)\n".utf8)) } }
        }
        if let failure {
            FileHandle.standardError.write(Data((positionalHelp(fullMessage(for: failure)) + "\n").utf8))
            Darwin.exit(exitCode(for: failure).rawValue)
        }
    }

    static func positionalHelp(_ text: String) -> String {
        let name = NSRegularExpression.escapedPattern(for: _commandName)
        let formatted = text.replacingOccurrences(of: "(See '\(name)) help([^']*) <subcommand>'", with: "$1$2 <subcommand> help'", options: .regularExpression)
            .replacingOccurrences(of: "(See '\(name)[^']*) --help'", with: "$1 help'", options: .regularExpression)
        guard let usage = formatted.range(of: "(?m)^USAGE: \(name)(?: [a-z][a-z-]*)*", options: .regularExpression) else { return formatted }
        let command = formatted[usage].dropFirst("USAGE: ".count)
        return formatted.replacingOccurrences(of: "(?m)^  -h, --help[^\\n]*", with: "\nHELP: \(command) help", options: .regularExpression)
    }
    static let configuration = CommandConfiguration(
        commandName: "nb",
        abstract: "Create, edit and organize Apple Notes from the terminal",
        subcommands: [Folders.self, MakeFolder.self, RemoveFolder.self, List.self, Stats.self, Show.self, Search.self, New.self, Remove.self, Move.self, Pin.self, Unpin.self, Append.self, Replace.self, Attach.self, Tables.self, SnapshotDatabase.self, Backup.self, Restore.self, Inspect.self, Edit.self, Insert.self, Format.self, Tags.self, Links.self, Attachments.self, ImportBear.self, Sync.self]
    )
}
