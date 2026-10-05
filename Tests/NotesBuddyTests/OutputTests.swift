import Foundation
import Darwin
import SQLite3
import XCTest
import ArgumentParser
@testable import notes_buddy

final class OutputTests: XCTestCase {
    func testActionPrintsTheFullObjectUUIDInsteadOfTheInputPrefix() throws {
        let uuid = "4B34F396-8895-4AC0-B593-28A8C5DD3521"
        let pipe = Pipe()
        fflush(stdout)
        let original = dup(STDOUT_FILENO)
        defer { dup2(original, STDOUT_FILENO); close(original) }
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        try OutputOptions.parse([]).writeAction("pin", ["id": uuid, "title": "Fixture", "folderPath": "Demo"])
        fflush(stdout)
        dup2(original, STDOUT_FILENO)
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), uuid + "\n")
    }

    func testJSONFilePathsAndURLsRemainReadable() throws {
        let output = try OutputOptions.parse(["--json"])
        let text = try output.format(["path": "/tmp/report.pdf", "url": "file:///tmp/report.pdf"])
        XCTAssertTrue(text.contains("/tmp/report.pdf"))
        XCTAssertTrue(text.contains("file:///tmp/report.pdf"))
        XCTAssertFalse(text.contains("\\/"))
    }
    func testActionResultsIdentifySavedObjectsWithoutClaimingSynchronization() throws {
        let output = OutputOptions()
        let value = output.actionResult("mkfolder", data: ["id": "folder-id", "path": "Work", "noteCount": 0, "empty": true, "needsCloudPush": true, "cloudAcknowledged": false, "inCloud": false])
        XCTAssertEqual(value["action"] as? String, "mkfolder")
        XCTAssertEqual(value["saved"] as? Bool, true)
        XCTAssertEqual(value["noteCount"] as? Int, 0)
        XCTAssertNil(value["synced"])
        XCTAssertNil(value["needsCloudPush"])
        XCTAssertNil(value["cloudAcknowledged"])
        XCTAssertNil(value["inCloud"])
        XCTAssertEqual(output.actionSummary(value), "mkfolder: Work, 0 notes, empty=true")
    }
    func testActionsRejectOptionsThatTheyWouldOtherwiseIgnore() throws {
        let attachmentCases = [
            ["ls", "fixture", "--file", "unused"], ["ls", "fixture", "--to", "unused"],
            ["ls", "fixture", "--size", "99"], ["ls", "fixture", "--attachment", "unused"],
            ["export", "fixture", "--before", "unused"], ["add", "fixture", "--attachment", "unused"],
            ["rm", "fixture", "--file", "unused"], ["replace", "fixture", "--to", "unused"],
            ["mv", "fixture", "--size", "1"], ["view", "fixture", "--after", "unused"],
            ["view", "fixture", "--size", "99"]
        ]
        for arguments in attachmentCases {
            XCTAssertThrowsError(try Attachments.parse(arguments), arguments.joined(separator: " "))
        }
        for arguments in [
            ["ls", "fixture", "--to", "unused"], ["ls", "fixture", "--link", "unused"],
            ["ls", "fixture", "--before", "unused"], ["add", "fixture", "--link", "unused"],
            ["rm", "fixture", "--to", "unused"], ["rm", "fixture", "--after", "unused"]
        ] {
            XCTAssertThrowsError(try Links.parse(arguments), arguments.joined(separator: " "))
        }
    }
    func testAttachmentExportNamesAndChecksTheWholeBatchBeforeCopying() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("receipt.txt")
        let nested = directory.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let second = nested.appendingPathComponent("receipt.txt")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let items: [[String: Any]] = [
            ["id": "one", "path": first.path, "available": true],
            ["id": "two", "path": second.path, "available": true],
            ["id": "table", "type": "com.apple.notes.table", "available": false]
        ]
        let output = directory.appendingPathComponent("saved")
        let command = try Attachments.parse(["export", "fixture", "--directory", output.path])
        let files = try command.exportFiles(items)
        XCTAssertEqual(files.map { URL(fileURLWithPath: $0["path"]!).lastPathComponent }, ["receipt.txt", "receipt (2).txt"])
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("receipt (2).txt")), Data("second".utf8))
        let conflict = directory.appendingPathComponent("conflict")
        try FileManager.default.createDirectory(at: conflict, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: conflict.appendingPathComponent("receipt (2).txt"))
        let conflicting = try Attachments.parse(["export", "fixture", "--directory", conflict.path])
        XCTAssertThrowsError(try conflicting.exportFiles(items))
        XCTAssertFalse(FileManager.default.fileExists(atPath: conflict.appendingPathComponent("receipt.txt").path))
        XCTAssertEqual(try Data(contentsOf: conflict.appendingPathComponent("receipt (2).txt")), Data("keep".utf8))
        let missing = directory.appendingPathComponent("missing")
        let unavailable = try Attachments.parse(["export", "fixture", "--directory", missing.path])
        XCTAssertThrowsError(try unavailable.exportFiles([items[0], ["id": "missing", "available": false]]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertTrue(try unavailable.exportFiles([]).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let selected = try Attachments.parse(["export", "fixture", "--attachment", "two", "--file", directory.appendingPathComponent("single.txt").path])
        XCTAssertEqual(try selected.exportFiles(items).first?["attachment"], "two")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("single.txt")), Data("second".utf8))
        let invalid = try Attachments.parse(["export", "fixture", "--file", "unused.txt"])
        XCTAssertThrowsError(try invalid.exportFiles(items))
        let combined = try Attachments.parse(["export", "fixture", "--file", "unused.txt", "--directory", output.path])
        XCTAssertThrowsError(try combined.exportFiles(items))
    }
    func testNativeObjectsUseTextByDefaultAndPreserveJSONValues() throws {
        let value: [String: Any] = ["id": "fixture", "text": "First\nSecond", "tags": [["name": "alpha"]], "tables": [[["A", "B"]]], "deleted": true, "files": 1, "links": []]
        let plain = try OutputOptions.parse([]).format(value)
        XCTAssertThrowsError(try JSONSerialization.jsonObject(with: Data(plain.utf8)))
        XCTAssertTrue(plain.contains("deleted: true"), plain)
        XCTAssertTrue(plain.contains("files: 1"), plain)
        XCTAssertTrue(plain.contains("tags:\n"), plain)
        XCTAssertTrue(plain.contains("name: alpha"), plain)
        let json = try OutputOptions.parse(["--json"]).format(value)
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
        XCTAssertEqual(decoded, value as NSDictionary)
    }

    func testEveryCommandParsesJSONWithoutRunning() throws {
        let commands: [[String]] = [
            [], ["folders"], ["stats"], ["stats", "--folder", "Fixture"], ["backup", "fixture-backup"], ["restore", "fixture-backup", "--to", "fixture-restored"], ["mkfolder", "Fixture"], ["rmfolder", "Fixture"], ["ls"], ["show", "fixture"], ["inspect", "fixture"],
            ["search", "query"], ["new", "--folder", "Fixture"], ["rm", "fixture"], ["mv", "fixture", "--folder", "Fixture"],
            ["pin", "fixture"], ["unpin", "fixture"],
            ["edit", "fixture", "--find", "A", "--with", "B"], ["insert", "fixture", "--text", "help"],
            ["format", "fixture", "--find", "A", "--style", "bold"], ["append", "fixture", "--html", "fixture.html"],
            ["replace", "fixture", "--find", "A", "--with", "B"], ["attach", "fixture", "fixture.pdf"], ["tags", "fixture"],
            ["table"], ["table", "ls", "fixture"], ["table", "new", "fixture", "--size", "2x2"],
            ["table", "set", "fixture", "--row", "1", "--col", "1", "--value", "A"],
            ["table", "add-row", "fixture"], ["table", "rm-row", "fixture", "--row", "1"],
            ["table", "add-col", "fixture"], ["table", "rm-col", "fixture", "--col", "1"],
            ["snapshot-db", "fixture.sqlite"], ["import-bear", "--dry-run"], ["sync", "--status"]
        ] + ["ls", "export", "add", "rm", "replace", "mv", "view"].map { ["attachments", $0, "fixture"] }
          + ["ls", "add", "rm"].map { ["links", $0, "fixture"] }
        for command in commands {
            XCTAssertNoThrow(try NotesBuddy.parseAsRoot(command + ["--json"]), command.joined(separator: " "))
            XCTAssertNoThrow(try NotesBuddy.parseAsRoot(["--json"] + command), command.joined(separator: " "))
        }
        for arguments in [["--json", "search", "query"], ["search", "query", "--json"]] {
            let command = try XCTUnwrap(try NotesBuddy.parseAsRoot(arguments) as? Search)
            XCTAssertTrue(command.output.json)
        }
    }

    func testSnapshotSupportsTextAndJSONOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TABLE fixture(value TEXT)", nil, nil, nil), SQLITE_OK)
        for json in [false, true] {
            let destination = directory.appendingPathComponent(json ? "json.sqlite" : "text.sqlite")
            let arguments = ["snapshot-db", destination.path, "--database", source.path] + (json ? ["--json"] : [])
            let result = try run(arguments)
            XCTAssertEqual(result.code, 0, result.error)
            XCTAssertTrue(result.error.isEmpty, result.error)
            if json {
                let value = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
                XCTAssertEqual(value?["path"] as? String, destination.path)
            } else {
                XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), destination.path)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testJSONFlagKeepsHelpAndErrorsAsText() throws {
        let help = try run(["search", "help", "--json"])
        XCTAssertEqual(help.code, 0)
        XCTAssertTrue(help.output.contains("USAGE: nb search"))
        XCTAssertTrue(help.error.isEmpty)
        let failure = try run(["search", "query", "--field", "invalid", "--json"])
        XCTAssertNotEqual(failure.code, 0)
        XCTAssertTrue(failure.output.isEmpty)
        XCTAssertTrue(failure.error.contains("Error:"), failure.error)
    }

    private func run(_ arguments: [String]) throws -> (code: Int32, output: String, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ".build/debug/nb")
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text, message)
    }
}
