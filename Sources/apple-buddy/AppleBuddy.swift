import ArgumentParser
import Foundation
import Darwin
import NotesNative

@main
struct AppleBuddy: ParsableCommand {
    static let releaseVersion = "1.0.0"
    @OptionGroup var output: OutputOptions
    static func main() {
        var commandType: ParsableCommand.Type = Self.self
        let arguments = aliasedArguments(program: CommandLine.arguments.first ?? "", Array(CommandLine.arguments.dropFirst()))
        let environment = ProcessInfo.processInfo.environment
        if AppLaunch.shouldRunInApp(arguments: arguments, environment: environment) {
            do { Darwin.exit(try AppLaunch.run(arguments: arguments, environment: environment)) } catch {
                FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
                Darwin.exit(1)
            }
        }
        AppLaunch.reportExitAtExit(environment: environment)
        for (index, argument) in arguments.enumerated() {
            if argument == "--json" && commandType._commandName == configuration.commandName { continue }
            if argument == "help" {
                print(positionalHelp(helpMessage(for: commandType)))
                return
            }
            var unusedOptions: Set<String>?
            if commandType == Attachments.self, let action = Attachments.Action(rawValue: argument) {
                unusedOptions = Set(Attachments.optionsForActions.filter { !$0.value.contains(action) }.keys)
            }
            if commandType == Links.self, let action = Links.Action(rawValue: argument) {
                unusedOptions = Set(Links.optionsForActions.filter { !$0.value.contains(action) }.keys)
            }
            if let unusedOptions, arguments.dropFirst(index + 1).first == "help" {
                print(actionHelp(positionalHelp(helpMessage(for: commandType)), command: commandType._commandName, action: argument, without: unusedOptions))
                return
            }
            guard let subcommand = commandType.configuration.subcommands.first(where: { $0._commandName == argument }) else { break }
            commandType = subcommand
        }
        var failure: Error?
        do {
            var command = try parseAsRoot(arguments)
            try autoreleasepool { try command.run() }
        } catch {
            if exitCode(for: error) == .success { print(positionalHelp(fullMessage(for: error))) }
            else { failure = error }
        }
        if let failure {
            FileHandle.standardError.write(Data((inputErrorMessage(fullMessage(for: failure)) + "\n").utf8))
            AppLaunch.status = exitCode(for: failure).rawValue
            Darwin.exit(AppLaunch.status)
        }
    }

    static func inputErrorMessage(_ text: String) -> String {
        positionalHelp(text)
            .replacingOccurrences(of: "Unexpected argument", with: "Unknown command or extra argument")
            .replacingOccurrences(of: "Missing expected argument", with: "Provide the argument")
            .replacingOccurrences(of: "Unknown option", with: "Unsupported option")
    }

    static func actionHelp(_ text: String, command: String, action: String, without options: Set<String>) -> String {
        var skipping = false
        return text.components(separatedBy: "\n").compactMap { line -> String? in
            if line.hasPrefix("  --") { skipping = options.contains { line.hasPrefix("  --\($0) <") } }
            else if !line.hasPrefix("    ") { skipping = false }
            if skipping || (line.hasPrefix("  abdy notes \(command) ") && !line.hasPrefix("  abdy notes \(command) \(action) ")) { return nil }
            guard line.hasPrefix("USAGE: ") else { return line }
            return options.reduce(line.replacingOccurrences(of: "<action>", with: action)) { $0.replacingOccurrences(of: " [--\($1) <\($1)>]", with: "") }
        }.joined(separator: "\n")
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
    static func aliasedArguments(program: String, _ arguments: [String]) -> [String] {
        guard URL(fileURLWithPath: program).lastPathComponent == "nb" else { return arguments }
        if let first = arguments.first, ["mcp", "version", "--version"].contains(first) { return arguments }
        return ["notes"] + arguments
    }

    static let configuration = CommandConfiguration(
        commandName: "abdy",
        abstract: "Create, edit and organize Apple Notes, Reminders and Calendar from the terminal",
        version: releaseVersion,
        subcommands: [Notes.self, Reminders.self, CalendarGroup.self, Version.self, MCPCommand.self]
    )
}

struct Notes: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create, edit and organize Apple Notes",
        subcommands: [Folders.self, MakeFolder.self, RemoveFolder.self, MoveFolder.self, RenameFolder.self, List.self, Duplicates.self, Stats.self, Show.self, OpenNote.self, Search.self, New.self, Remove.self, Move.self, Pin.self, Unpin.self, Append.self, Replace.self, Attach.self, Tables.self, SnapshotDatabase.self, Backup.self, Restore.self, Inspect.self, Edit.self, Insert.self, Format.self, Tags.self, Links.self, Attachments.self, ImportBear.self, Sync.self]
    )
}

struct Version: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        abstract: "Show the installed release version",
        discussion: "Prints the version without reading Notes or starting synchronization. With --json returns name and version. Example: abdy version --json"
    )

    func run() throws {
        try output.write(["name": "apple-buddy", "version": AppleBuddy.releaseVersion], text: AppleBuddy.releaseVersion)
    }
}
