import Foundation
import SQLite3
import XCTest
@testable import notes_buddy

final class BearImportTests: XCTestCase {
    func testImportVerificationRejectsTheWrongFolderPath() throws {
        let note = BearNote(key: "1", identifier: "source", title: "Receipt", text: "Receipt", tags: ["bills/gas"])
        let state: [AnyHashable: Any] = ["text": "Receipt", "attachments": [], "tags": [["name": "#bills"], ["name": "#gas"]], "folderPath": "gas"]
        XCTAssertThrowsError(try verifyBearNote(note, state: state, digests: [:]))
        var correct = state
        correct["folderPath"] = "bills/gas"
        XCTAssertEqual(try verifyBearNote(note, state: correct, digests: [:]), 0)
    }

    func testDryRunRejectsTagsThatNotesCannotStoreBeforeAnyChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("database.sqlite").path, &database), SQLITE_OK)
        let sql = """
        CREATE TABLE ZSFNOTE (Z_PK INTEGER, ZUNIQUEIDENTIFIER TEXT, ZTITLE TEXT, ZTEXT TEXT, ZENCRYPTED INTEGER, ZTRASHED INTEGER, ZPERMANENTLYDELETED INTEGER);
        CREATE TABLE ZSFNOTETAG (Z_PK INTEGER, ZTITLE TEXT);
        CREATE TABLE Z_5TAGS (Z_5NOTES INTEGER, Z_13TAGS INTEGER);
        CREATE TABLE ZSFNOTEFILE (ZNOTE INTEGER, ZUNIQUEIDENTIFIER TEXT, ZFILENAME TEXT, ZDOWNLOADED INTEGER, ZENCRYPTED INTEGER, ZUNUSED INTEGER, ZPERMANENTLYDELETED INTEGER, ZINDEX INTEGER, Z_PK INTEGER);
        INSERT INTO ZSFNOTE VALUES (1,'source-id','Code','# Code',0,0,0);
        INSERT INTO ZSFNOTETAG VALUES (1,'dev/c++'),(2,'my tag'),(3,'work/2024_q1-plan');
        INSERT INTO Z_5TAGS VALUES (1,1),(1,2),(1,3);
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ".build/debug/nb")
        process.arguments = ["import-bear", "--source", directory.path, "--dry-run"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1, message)
        XCTAssertTrue(text.isEmpty, text)
        XCTAssertTrue(message.contains("Bear tags are not valid Notes tags: dev/c++, my tag"), message)
    }

    func testMarkdownSeparatorsAreContentNotYAML() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let html = try renderBearHTML("# Receipt\n\n---\n\nThis is a receipt.\n\n---\nSENTRY RECEIPT -\n\nUser: billing@example.com\nAmount: $29.00\n\n---\nEnd", pandoc: "/opt/homebrew/bin/pandoc", directory: directory)
        XCTAssertTrue(html.contains("This is a receipt."))
        XCTAssertTrue(html.contains("$29.00"))
    }
    func testReadsImageStorageAndBuildsStableAttachmentAnchors() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("Local Files/Note Images/image-id/photo.png")
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: image)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("database.sqlite").path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE ZSFNOTE (Z_PK INTEGER, ZUNIQUEIDENTIFIER TEXT, ZTITLE TEXT, ZTEXT TEXT, ZENCRYPTED INTEGER, ZTRASHED INTEGER, ZPERMANENTLYDELETED INTEGER);
        CREATE TABLE ZSFNOTETAG (Z_PK INTEGER, ZTITLE TEXT);
        CREATE TABLE Z_5TAGS (Z_5NOTES INTEGER, Z_13TAGS INTEGER);
        CREATE TABLE ZSFNOTEFILE (ZNOTE INTEGER, ZUNIQUEIDENTIFIER TEXT, ZFILENAME TEXT, ZDOWNLOADED INTEGER, ZENCRYPTED INTEGER, ZUNUSED INTEGER, ZPERMANENTLYDELETED INTEGER, ZINDEX INTEGER, Z_PK INTEGER);
        INSERT INTO ZSFNOTE VALUES (1,'source-id','Photo','# Photo\n![[photo.png]]\n#travel/japan',0,0,0);
        INSERT INTO ZSFNOTETAG VALUES (1,'travel/japan');
        INSERT INTO Z_5TAGS VALUES (1,1);
        INSERT INTO ZSFNOTEFILE VALUES (1,'image-id','photo.png',1,0,0,0,0,1);
        """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        let note = try XCTUnwrap(readBearNotes(at: directory).first)
        XCTAssertEqual(note.files, [image.path])
        XCTAssertEqual(note.destination, "travel/japan")
        XCTAssertNotNil(UUID(uuidString: note.notesIdentifier))
        XCTAssertEqual(note.notesIdentifier, try readBearNotes(at: directory).first?.notesIdentifier)
        XCTAssertTrue(bearMarkdown(note).contains("NBATTACHMENT0_"))
        XCTAssertFalse(bearMarkdown(note).contains("#travel"))
        XCTAssertFalse(bearMarkdown(note).contains("photo.png"))
    }
}
