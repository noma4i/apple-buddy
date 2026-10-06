import Foundation
import SQLite3
import XCTest

final class SnapshotTests: XCTestCase {
    func testSnapshotIncludesCommittedWALAndPreservesSource() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite")
        let destination = directory.appendingPathComponent("snapshot.sqlite")
        let database = try openDatabase(source)
        defer { sqlite3_close(database) }
        try execute(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES('from WAL');")
        let before = try Data(contentsOf: source)
        let wal = URL(fileURLWithPath: source.path + "-wal")
        let walBefore = try Data(contentsOf: wal)

        let result = try runSnapshot(source: source, destination: destination)

        XCTAssertEqual(result.status, 0, result.output)
        guard result.status == 0 else { return }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + "-shm"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + "-wal"))
        XCTAssertEqual(try Data(contentsOf: source), before)
        XCTAssertEqual(try Data(contentsOf: wal), walBefore)
        let copy = try openDatabase(destination, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(copy) }
        XCTAssertEqual(try scalar(copy, "SELECT value FROM sample"), "from WAL")
        XCTAssertEqual(try scalar(copy, "PRAGMA integrity_check"), "ok")
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testExistingDestinationIsNeverOverwritten() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite")
        let database = try openDatabase(source)
        defer { sqlite3_close(database) }
        try execute(database, "CREATE TABLE sample(value TEXT)")
        let destination = directory.appendingPathComponent("existing.sqlite")
        let original = Data("preserve this file".utf8)
        try original.write(to: destination)

        let result = try runSnapshot(source: source, destination: destination)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("destination already exists"), result.output)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testInvalidSourceLeavesNoSnapshot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("invalid.sqlite")
        let original = Data("not a SQLite database".utf8)
        try original.write(to: source)
        let destination = directory.appendingPathComponent("snapshot.sqlite")

        let result = try runSnapshot(source: source, destination: destination)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("not a database"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func openDatabase(_ url: URL, flags: Int32 = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) throws -> OpaquePointer {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw NSError(domain: "SQLite", code: Int(status))
        }
        return database
    }

    private func execute(_ database: OpaquePointer, _ sql: String) throws {
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw NSError(domain: "SQLite", code: Int(status)) }
    }

    private func scalar(_ database: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard status == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw NSError(domain: "SQLite", code: Int(sqlite3_errcode(database)))
        }
        return String(cString: value)
    }

    private func runSnapshot(source: URL, destination: URL) throws -> (status: Int32, output: String) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = nbBinaryURL()
        process.arguments = ["snapshot-db", destination.path, "--database", source.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
