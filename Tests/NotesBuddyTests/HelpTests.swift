import Foundation
import XCTest

final class HelpTests: XCTestCase {
    func testExecutableIsNamedNB() throws {
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: ".build/debug/nb"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ".build/debug/nb")
        process.arguments = ["help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() }
        catch { XCTFail("Cannot launch nb: \(error)"); return }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(text.contains("USAGE: nb"), text)
        XCTAssertFalse(text.contains("notes-buddy"), text)
    }
    func testPinCommandsHavePositionalHelpAndJSONWithoutOpeningNotes() throws {
        for command in ["pin", "unpin"] {
            let (code, text) = try output([command, "help", "invalid-id", "--json"])
            XCTAssertEqual(code, 0, text)
            XCTAssertTrue(text.contains("USAGE: nb " + command), text)
            XCTAssertTrue(text.contains("--json"), text)
            XCTAssertTrue(text.contains("HELP: nb " + command + " help"), text)
            XCTAssertFalse(text.contains("-h, --help"), text)
        }
        let (_, root) = try output(["help"])
        XCTAssertTrue(root.contains("pin"), root)
        XCTAssertTrue(root.contains("unpin"), root)
    }
    func testRootHelpContainsOnlyTheCommandReference() throws {
        let (code, text) = try output(["help"])
        XCTAssertEqual(code, 0)
        XCTAssertTrue(text.contains("USAGE: nb"))
        XCTAssertTrue(text.contains("SUBCOMMANDS:"))
        XCTAssertTrue(text.contains("OPTIONS:"))
        XCTAssertFalse(text.contains("Uses this computer"), text)
        XCTAssertFalse(text.contains("acknowledgement"), text)
        XCTAssertFalse(text.contains("EXAMPLES"), text)
        XCTAssertFalse(text.contains("See README"), text)
    }
    func testValidationErrorsPointToPositionalHelp() throws {
        for (arguments, command) in [(["search", "--field", "invalid"], "search"), (["table", "set"], "table set"), (["unknown"], "")] {
            let (code, text) = try output(arguments)
            XCTAssertNotEqual(code, 0)
            XCTAssertTrue(text.contains("See '" + (["nb", command, "help"].filter { !$0.isEmpty }).joined(separator: " ") + "' for more information."), text)
            XCTAssertFalse(text.contains("--help"), text)
        }
    }
    func testHelpAdvertisesThePositionalCommandInsteadOfFlags() throws {
        for command in [[], ["sync"], ["search"], ["attachments"], ["table", "set"]] {
            let (code, text) = try output(command + ["help"])
            XCTAssertEqual(code, 0)
            XCTAssertTrue(text.contains("HELP: " + (["nb"] + command + ["help"]).joined(separator: " ")), text)
            XCTAssertFalse(text.contains("-h, --help"), text)
        }
    }
    func testSyncHelpIsACompactCommandReference() throws {
        let (code, text) = try output(["sync", "help"])
        XCTAssertEqual(code, 0)
        XCTAssertLessThanOrEqual(text.split(separator: "\n", omittingEmptySubsequences: false).count, 24, text)
        XCTAssertTrue(text.contains("USAGE: nb sync"))
        XCTAssertTrue(text.contains("--status"))
        XCTAssertTrue(text.contains("--json"))
        XCTAssertFalse(text.contains("AppleScript"), text)
        XCTAssertFalse(text.contains("SIGTERM"), text)
    }
    func testHelpFooterUsesHelpAfterTheCommand() throws {
        for words in [[], ["table"]] {
            for option in ["help", "--help"] {
                let (code, text) = try output(words + [option])
                XCTAssertEqual(code, 0)
                let prefix = (["nb"] + words).joined(separator: " ")
                XCTAssertTrue(text.contains("See '\(prefix) <subcommand> help' for detailed help."), text)
                XCTAssertFalse(text.contains("nb help <subcommand>"), text)
            }
        }
    }
    func testPositionalActionsHaveBareHelpWithoutReadingNotes() throws {
        let commands = ["ls", "export", "add", "rm", "replace", "mv", "view"].map { ["attachments", $0] }
          + ["ls", "add", "rm"].map { ["links", $0] }
        for command in commands {
            let (code, text) = try output(command + ["help", "invalid-id", "--json"])
            XCTAssertEqual(code, 0, "\(command): \(text)")
            XCTAssertTrue(text.contains("USAGE: nb " + command[0]), "\(command): \(text)")
            XCTAssertTrue(text.contains("OVERVIEW:"), "\(command): \(text)")
        }
        for command in [["attachments", "rm", "invalid-id", "help"], ["links", "add", "invalid-id", "help"], ["attachments", "invalid", "help"]] {
            let (code, text) = try output(command)
            XCTAssertNotEqual(code, 0, "\(command): \(text)")
            XCTAssertFalse(text.contains("OVERVIEW:"), "\(command): \(text)")
        }
    }

    func testBareHelpWorksImmediatelyAfterEveryCommand() throws {
        let commands = ["", "folders", "mkfolder", "rmfolder", "ls", "show", "search", "new", "rm", "mv", "append", "replace", "attach", "inspect", "edit", "insert", "format", "tags", "links", "attachments", "snapshot-db", "import-bear", "sync", "table", "table ls", "table new", "table set", "table add-row", "table rm-row", "table add-col", "table rm-col"]
        for command in commands {
            let words = command.split(separator: " ").map(String.init)
            let arguments = words + ["help"]
            let (code, output) = try output(arguments)
            XCTAssertEqual(code, 0, "\(arguments): \(output)")
            XCTAssertTrue(output.contains("USAGE: nb" + (command.isEmpty ? "" : " " + command)), "\(arguments): \(output)")
        }
    }

    func testBareHelpOverridesArgumentsAndValidation() throws {
        let cases: [([String], String)] = [
            (["table", "set", "help", "invalid-id", "--row", "invalid"], "table set"),
            (["rm", "help", "invalid-id"], "rm"),
            (["search", "help", "--field", "invalid"], "search"),
            (["new", "help", "--folder", "missing"], "new"),
            (["help", "table", "set"], ""),
            (["table", "help", "set"], "table"),
            (["attachments", "help", "rm", "invalid-id"], "attachments"),
            (["links", "help", "add", "invalid-id"], "links")
        ]
        for (arguments, command) in cases {
            let (code, output) = try output(arguments)
            XCTAssertEqual(code, 0, "\(arguments): \(output)")
            let usage = output.split(separator: "\n").first { $0.hasPrefix("USAGE:") }
            XCTAssertTrue(usage?.hasPrefix("USAGE: nb " + command) == true, "\(arguments): \(output)")
            if command.isEmpty { XCTAssertFalse(usage?.contains(" table") == true, "\(arguments): \(output)") }
            XCTAssertFalse(output.contains("Sync request failed"))
            XCTAssertFalse(output.contains("Error:"), "\(arguments): \(output)")
        }
    }

    func testHelpOutsideCommandPositionDoesNotRequestHelp() throws {
        for arguments in [["search", "query", "help"], ["table", "set", "invalid-id", "help"], ["search", "--field", "help", "--limit", "invalid"]] {
            let (code, output) = try output(arguments)
            XCTAssertNotEqual(code, 0, "\(arguments): \(output)")
            XCTAssertFalse(output.contains("OVERVIEW:"), "\(arguments): \(output)")
        }
    }

    private func output(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ".build/debug/nb")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    func testSearchNeedsNoFuzzyOrDocumentScanningFlags() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ".build/debug/nb")
        process.arguments = ["search", "--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(output.contains("--fuzzy"))
        XCTAssertFalse(output.contains("--scan-documents"))
        XCTAssertTrue(output.contains("Fuzzy matching is enabled by default"))
        XCTAssertTrue(output.contains("all searches document contents automatically"))
    }

    func testWritesAlwaysExplainCloudAcknowledgement() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ".build/debug/nb")
        process.arguments = ["sync", "help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(output.contains("--no-sync"))
        XCTAssertTrue(output.contains("Writes sync automatically"))
        XCTAssertTrue(output.contains("Success confirms iCloud acknowledgement"))
    }

    func testEveryCommandHasItsOwnUsageHelp() throws {
        let commands = ["", "folders", "mkfolder", "rmfolder", "ls", "show", "search", "new", "rm", "mv", "append", "replace", "attach", "inspect", "edit", "insert", "format", "tags", "links", "attachments", "snapshot-db", "import-bear", "sync", "table", "table ls", "table new", "table set", "table add-row", "table rm-row", "table add-col", "table rm-col"]
        for command in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ".build/debug/nb")
            process.arguments = command.split(separator: " ").map(String.init) + ["--help"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(command): \(output)")
            XCTAssertFalse(output.contains("--quit-notes"), "\(command): automatic quit must not require a flag")
            XCTAssertTrue(output.contains("--json"), "\(command): JSON output must be available")
            XCTAssertTrue(output.contains("USAGE: nb" + (command.isEmpty ? "" : " " + command)), "\(command): \(output)")
        }
    }
}
