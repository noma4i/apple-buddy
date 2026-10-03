import Foundation
import XCTest

final class HelpTests: XCTestCase {
    func testSearchNeedsNoFuzzyOrDocumentScanningFlags() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ".build/debug/notes-buddy")
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
        process.executableURL = URL(fileURLWithPath: ".build/debug/notes-buddy")
        process.arguments = ["--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(output.contains("--no-sync"))
        XCTAssertTrue(output.contains("Every write waits for iCloud acknowledgement"))
    }

    func testEveryCommandHasItsOwnUsageHelp() throws {
        let commands = ["", "folders", "mkfolder", "rmfolder", "ls", "show", "search", "new", "rm", "mv", "append", "replace", "attach", "inspect", "edit", "insert", "format", "tags", "links", "attachments", "snapshot-db", "import-bear", "sync", "table", "table ls", "table new", "table set", "table add-row", "table rm-row", "table add-col", "table rm-col"]
        for command in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ".build/debug/notes-buddy")
            process.arguments = command.split(separator: " ").map(String.init) + ["--help"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(command): \(output)")
            XCTAssertFalse(output.contains("--quit-notes"), "\(command): automatic quit must not require a flag")
            XCTAssertTrue(output.contains("USAGE: notes-buddy" + (command.isEmpty ? "" : " " + command)), "\(command): \(output)")
        }
    }
}
