import CoreData
import Darwin
import Foundation
import NotesNative
import SQLite3
import XCTest

final class BackupTests: XCTestCase {
    private var directory: URL!
    private var source: URL!
    private var database: OpaquePointer?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        source = directory.appendingPathComponent("Library/Group Containers/group.com.apple.notes")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = dlopen("/System/Library/PrivateFrameworks/NotesShared.framework/NotesShared", RTLD_LAZY)
        let stores = NSPersistentStoreCoordinator(managedObjectModel: try XCTUnwrap(NBNotes.installedModel()))
        let store = try stores.addPersistentStore(type: .sqlite, at: source.appendingPathComponent("NoteStore.sqlite"), options: [NSPersistentHistoryTrackingKey: true])
        try stores.remove(store)
        XCTAssertEqual(sqlite3_open(source.appendingPathComponent("NoteStore.sqlite").path, &database), SQLITE_OK)
        try execute("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE backup_sample(value TEXT); INSERT INTO backup_sample VALUES('rich document bytes');")
        let media = source.appendingPathComponent("Accounts/demo/Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try Data("PDF bytes".utf8).write(to: media.appendingPathComponent("invoice.pdf"))
        try Data("Image bytes".utf8).write(to: media.appendingPathComponent("image.png"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("empty"), withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let database { sqlite3_close(database) }
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    func testBackupAndIsolatedRestorePreserveWALFilesAndSource() throws {
        let sqlite = source.appendingPathComponent("NoteStore.sqlite")
        let before = try Data(contentsOf: sqlite)
        let wal = try Data(contentsOf: URL(fileURLWithPath: sqlite.path + "-wal"))
        let backup = directory.appendingPathComponent("backup")
        let restored = directory.appendingPathComponent("restored")
        let saved = try run(["backup", backup.path, "--json"])
        XCTAssertEqual(saved.code, 0, saved.text)
        guard saved.code == 0 else { return }
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(saved.text.utf8)) as? [String: Any])
        XCTAssertEqual(result["path"] as? String, backup.path)
        let recovered = try run(["restore", backup.path, "--to", restored.path])
        XCTAssertEqual(recovered.code, 0, recovered.text)
        XCTAssertEqual(recovered.text.trimmingCharacters(in: .whitespacesAndNewlines), restored.path)
        guard recovered.code == 0 else { return }
        for file in ["Accounts/demo/Media/invoice.pdf", "Accounts/demo/Media/image.png"] {
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(file)), try Data(contentsOf: restored.appendingPathComponent(file)))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.appendingPathComponent("empty").path))
        var copy: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(restored.appendingPathComponent("NoteStore.sqlite").path, &copy, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(copy) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(copy, "SELECT value FROM backup_sample", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "rich document bytes")
        XCTAssertEqual(try Data(contentsOf: sqlite), before)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sqlite.path + "-wal")), wal)
        for url in [backup, restored] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: restored.appendingPathComponent("NoteStore.sqlite").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRestoreRejectsCorruptionTraversalSymlinksAndWorkingNotes() throws {
        let backup = directory.appendingPathComponent("backup")
        let destination = directory.appendingPathComponent("restored")
        let saved = try run(["backup", backup.path])
        XCTAssertEqual(saved.code, 0, saved.text)
        guard saved.code == 0 else { return }
        let media = backup.appendingPathComponent("data/Accounts/demo/Media/invoice.pdf")
        let bytes = try Data(contentsOf: media)
        try Data("damaged".utf8).write(to: media)
        XCTAssertNotEqual(try run(["restore", backup.path, "--to", destination.path]).code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try bytes.write(to: media)
        let manifest = backup.appendingPathComponent("manifest.json")
        let original = try Data(contentsOf: manifest)
        var value = try XCTUnwrap(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        var files = try XCTUnwrap(value["files"] as? [[String: Any]])
        files[0]["path"] = "../escape"
        value["files"] = files
        try JSONSerialization.data(withJSONObject: value).write(to: manifest)
        let invalid = try run(["restore", backup.path, "--to", destination.path])
        XCTAssertNotEqual(invalid.code, 0, invalid.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try original.write(to: manifest)
        try FileManager.default.removeItem(at: media)
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: source.appendingPathComponent("Accounts/demo/Media/invoice.pdf"))
        XCTAssertNotEqual(try run(["restore", backup.path, "--to", destination.path]).code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try FileManager.default.removeItem(at: media)
        try bytes.write(to: media)
        let unsafe = try run(["restore", backup.path, "--to", source.appendingPathComponent("restore").path])
        XCTAssertNotEqual(unsafe.code, 0, unsafe.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("restore").path))
    }

    func testBackupAndRestoreNeverOverwriteOrAcceptNestedDestinations() throws {
        let backup = directory.appendingPathComponent("backup")
        let saved = try run(["backup", backup.path])
        XCTAssertEqual(saved.code, 0, saved.text)
        guard saved.code == 0 else { return }
        let manifest = try Data(contentsOf: backup.appendingPathComponent("manifest.json"))
        XCTAssertNotEqual(try run(["backup", backup.path]).code, 0)
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("manifest.json")), manifest)
        XCTAssertNotEqual(try run(["backup", source.appendingPathComponent("bad").path]).code, 0)
        XCTAssertNotEqual(try run(["restore", backup.path, "--to", backup.appendingPathComponent("bad").path]).code, 0)
        let existing = directory.appendingPathComponent("existing")
        try Data("keep".utf8).write(to: existing)
        XCTAssertNotEqual(try run(["restore", backup.path, "--to", existing.path]).code, 0)
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
    }

    func testBackupAndRestoreHelpNeverReadDatabase() throws {
        for command in ["backup", "restore"] {
            let result = try run([command, "help", "invalid", "--json"])
            XCTAssertEqual(result.code, 0, result.text)
            XCTAssertTrue(result.text.contains("HELP: nb \(command) help"), result.text)
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "fixture-sql", code: 1) }
    }

    private func run(_ arguments: [String]) throws -> (code: Int32, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ".build/debug/nb")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = directory.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
