import AppKit
import CryptoKit
import Foundation
import XCTest
@testable import apple_buddy

final class RemindersTests: XCTestCase {
    private var storeFile: URL!

    override func setUpWithError() throws {
        storeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeFile)
    }

    private func run(_ arguments: [String], stdin: String? = nil) throws -> (code: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ".build/debug/abdy")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ABDY_EVENT_STORE_FILE"] = storeFile.path
        process.environment = environment
        let output = Pipe(), errors = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        try process.run()
        if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text, error)
    }

    private func json(_ text: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) }

    func testAccessIsRequiredAndRequestedOnce() throws {
        let denied = try run(["reminders", "lists"])
        XCTAssertEqual(denied.code, 1)
        XCTAssertTrue(denied.err.contains("Reminders access is notDetermined. Run abdy reminders access"), denied.err)
        let granted = try run(["reminders", "access"])
        XCTAssertEqual(granted.code, 0, granted.err)
        XCTAssertEqual(granted.out, "fullAccess\n")
        XCTAssertEqual(try run(["reminders", "lists"]).code, 0)
        XCTAssertEqual(try run(["calendar", "calendars"]).code, 1, "calendar access is separate")
    }

    func testListsAreCreatedRenamedResolvedByNameAndRemoved() throws {
        _ = try run(["reminders", "access"])
        let made = try run(["reminders", "mklist", "Groceries"])
        XCTAssertEqual(made.code, 0, made.err)
        let id = made.out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(id.count, 36)
        XCTAssertTrue(made.err.hasPrefix("mklist: Groceries in On My Mac"), made.err)
        XCTAssertFalse(made.err.contains("notes sync"), made.err)
        _ = try run(["reminders", "mklist", "groceries", "--source", "Subscribed Calendars"])
        let ambiguous = try run(["reminders", "renamelist", "Groceries", "--name", "Food"])
        XCTAssertEqual(ambiguous.code, 1)
        XCTAssertTrue(ambiguous.err.contains("List name is ambiguous: Groceries. Use a UUID from abdy reminders lists: Groceries (On My Mac) \(id), groceries (Subscribed Calendars)"), ambiguous.err)
        let renamed = try run(["reminders", "renamelist", String(id.prefix(8)), "--name", "Food"])
        XCTAssertEqual(renamed.code, 0, renamed.err)
        let lists = try run(["reminders", "lists", "--json"])
        let objects = try XCTUnwrap(try json(lists.out) as? [[String: Any]])
        XCTAssertEqual(objects.map { $0["title"] as? String }, ["Food", "groceries"])
        XCTAssertEqual(objects.map { $0["readOnly"] as? Bool }, [false, true])
        XCTAssertEqual(objects.first?["count"] as? Int, 0)
        let readOnly = try run(["reminders", "rmlist", "groceries"])
        XCTAssertEqual(readOnly.code, 1)
        XCTAssertTrue(readOnly.err.contains("List groceries is read-only and cannot be removed"), readOnly.err)
        let missing = try run(["reminders", "rmlist", "Nope"])
        XCTAssertTrue(missing.err.contains("List not found: Nope. Use a name, a UUID or its prefix of at least 8 characters from abdy reminders lists"), missing.err)
        XCTAssertEqual(try run(["reminders", "rmlist", "Food"]).code, 0)
        XCTAssertEqual(try run(["reminders", "lists"]).err, "1 lists\n")
    }

    func testRemindersAddListShowEditDoneMoveAndRemove() throws {
        _ = try run(["reminders", "access"])
        _ = try run(["reminders", "mklist", "Home"])
        _ = try run(["reminders", "mklist", "Work"])
        let milk = try run(["reminders", "add", "Buy milk", "--list", "Home", "--due", "2026-10-07T18:00", "--alarm", "30", "--priority", "1", "--notes", "2 litres"])
        XCTAssertEqual(milk.code, 0, milk.err)
        let milkID = milk.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let rent = try run(["reminders", "add", "Pay rent", "--due", "2026-10-01", "--repeat", "monthly", "--count", "3"])
        XCTAssertEqual(rent.code, 0, rent.err)
        let rentID = rent.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let later = try run(["reminders", "add", "Someday", "--list", "Work"])
        let laterID = later.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let listed = try run(["reminders", "ls", "--long"])
        XCTAssertEqual(listed.code, 0, listed.err)
        let rows = listed.out.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(rows.map { $0[3] }, ["Pay rent", "Buy milk", "Someday"], "due dates first, then no due date")
        XCTAssertEqual(rows[0][1], "2026-10-01")
        XCTAssertEqual(rows[2][1], "")
        XCTAssertEqual(rows[1][2], "Home")
        XCTAssertEqual(listed.err, "3 reminders\n")
        XCTAssertTrue(rows[1][1].hasPrefix("2026-10-07T18:00:00"), rows[1][1])
        let shown = try run(["reminders", "show", String(milkID.prefix(8))])
        XCTAssertEqual(shown.code, 0, shown.err)
        XCTAssertTrue(shown.out.contains("Title: Buy milk\nList: Home\nDue: 2026-10-07T18:00:00"), shown.out)
        XCTAssertTrue(shown.out.contains("Priority: 1\nCompleted: false\nAlarms: 30 min before\n\n2 litres"), shown.out)
        let rentShown = try run(["reminders", "show", rentID, "--json"])
        let rentObject = try XCTUnwrap(try json(rentShown.out) as? [String: Any])
        XCTAssertEqual((rentObject["recurrence"] as? [String: Any])?["frequency"] as? String, "monthly")
        XCTAssertEqual((rentObject["recurrence"] as? [String: Any])?["count"] as? Int, 3)
        XCTAssertEqual(rentObject["due"] as? String, "2026-10-01T00:00:00+11:00".replacingOccurrences(of: "+11:00", with: DateText.stamp(DateArgument.parse("2026-10-01")!.date).suffix(6)))
        let edited = try run(["reminders", "edit", milkID, "--title", "Buy oat milk", "--clear-alarms", "--due", "2026-10-08T09:00"])
        XCTAssertEqual(edited.code, 0, edited.err)
        let editedObject = try XCTUnwrap(try json(try run(["reminders", "show", milkID, "--json"]).out) as? [String: Any])
        XCTAssertEqual(editedObject["title"] as? String, "Buy oat milk")
        XCTAssertEqual((editedObject["alarms"] as? [Int])?.count, 0)
        XCTAssertEqual(try run(["reminders", "edit", milkID, "--due", "2026-10-08", "--clear-due"]).code, 64)
        let done = try run(["reminders", "done", "-"], stdin: milkID + "\n" + rentID + "\n")
        XCTAssertEqual(done.code, 0, done.err)
        XCTAssertEqual(done.out, milkID + "\n" + rentID + "\n")
        XCTAssertEqual(done.err, "reminders done: 2 reminders completed\n")
        XCTAssertEqual(try run(["reminders", "ls"]).out, laterID + "\n")
        XCTAssertEqual(try run(["reminders", "ls", "--completed"]).out.split(separator: "\n").count, 2)
        XCTAssertEqual(try run(["reminders", "ls", "--all"]).err, "3 reminders\n")
        XCTAssertEqual(try run(["reminders", "search", "milk", "--all"]).out, milkID + "\n")
        XCTAssertEqual(try run(["reminders", "search", "milk"]).out, "")
        XCTAssertEqual(try run(["reminders", "undone", milkID]).code, 0)
        XCTAssertEqual(try run(["reminders", "ls", "--list", "Home", "--due-after", "2026-10-07"]).out, milkID + "\n")
        let moved = try run(["reminders", "mv", milkID, laterID, "--list", "Work", "--json"])
        XCTAssertEqual(moved.code, 0, moved.err)
        let movedObject = try XCTUnwrap(try json(moved.out) as? [String: Any])
        XCTAssertEqual(movedObject["action"] as? String, "reminders mv")
        XCTAssertEqual((movedObject["reminders"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(try run(["reminders", "ls", "--list", "Work"]).err, "2 reminders\n")
        let partial = try run(["reminders", "rm", milkID, "00000000-0000-0000-0000-000000000000"])
        XCTAssertEqual(partial.code, 1)
        XCTAssertTrue(partial.err.contains("Reminder not found: 00000000-0000-0000-0000-000000000000"), partial.err)
        XCTAssertEqual(try run(["reminders", "ls", "--all"]).err, "3 reminders\n", "a refused batch deletes nothing")
        XCTAssertEqual(try run(["reminders", "rm", milkID, laterID]).out, milkID + "\n" + laterID + "\n")
        XCTAssertEqual(try run(["reminders", "ls", "--all"]).err, "1 reminders\n")
    }

    func testAlarmsAreReportedInAscendingOrder() throws {
        _ = try run(["reminders", "access"])
        _ = try run(["reminders", "mklist", "Home"])
        let item = try run(["reminders", "add", "Order", "--list", "Home", "--due", "2026-10-20T09:00", "--alarm", "30", "--alarm", "5", "--alarm", "60"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        let object = try XCTUnwrap(try json(try run(["reminders", "show", item, "--json"]).out) as? [String: Any])
        XCTAssertEqual(object["alarms"] as? [Int], [5, 30, 60])
        XCTAssertTrue(try run(["reminders", "show", item]).out.contains("Alarms: 5 min before, 30 min before, 60 min before"))
    }

    func testReadOnlyListsRefuseWritesAndValidationHasExitCode64() throws {
        _ = try run(["reminders", "access"])
        _ = try run(["reminders", "mklist", "Feed", "--source", "Subscribed Calendars"])
        let refused = try run(["reminders", "add", "x", "--list", "Feed"])
        XCTAssertEqual(refused.code, 1)
        XCTAssertTrue(refused.err.contains("List Feed is read-only and cannot hold new reminders"), refused.err)
        XCTAssertEqual(try run(["reminders", "add", "x", "--repeat", "daily"]).code, 64, "--repeat needs --due")
        XCTAssertEqual(try run(["reminders", "add", "x", "--due", "yesterday"]).code, 64)
        XCTAssertEqual(try run(["reminders", "add", "x", "--priority", "12"]).code, 64)
        XCTAssertEqual(try run(["reminders", "add", "x"]).code, 1, "no default list yet")
    }

    func testLocationRemindersCarryPlaceRadiusAndProximity() throws {
        _ = try run(["reminders", "access"])
        _ = try run(["reminders", "mklist", "Errands"])
        let added = try run(["reminders", "add", "Return books", "--list", "Errands", "--arrive=-33.8688,151.2093", "--radius", "200"])
        XCTAssertEqual(added.code, 0, added.err)
        let id = added.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = try run(["reminders", "show", id])
        XCTAssertTrue(shown.out.contains("Location: arriving at -33.8688,151.2093 (-33.8688, 151.2093, 200 m)"), shown.out)
        let object = try XCTUnwrap(try json(try run(["reminders", "show", id, "--json"]).out) as? [String: Any])
        let location = try XCTUnwrap(object["location"] as? [String: Any])
        XCTAssertEqual(location["proximity"] as? String, "arrive")
        XCTAssertEqual(location["radius"] as? Double, 200)
        XCTAssertEqual(try run(["reminders", "edit", id, "--leave=-33.9,151.2", "--radius", "50"]).code, 0)
        let edited = try XCTUnwrap(try json(try run(["reminders", "show", id, "--json"]).out) as? [String: Any])
        XCTAssertEqual((edited["location"] as? [String: Any])?["proximity"] as? String, "leave")
        XCTAssertEqual(try run(["reminders", "edit", id, "--clear-location"]).code, 0)
        XCTAssertNil(try XCTUnwrap(try json(try run(["reminders", "show", id, "--json"]).out) as? [String: Any])["location"])
        XCTAssertEqual(try run(["reminders", "add", "x", "--list", "Errands", "--arrive", "a", "--leave", "b"]).code, 64)
        XCTAssertEqual(try run(["reminders", "add", "x", "--list", "Errands", "--arrive", "1,2", "--radius", "0"]).code, 64)
    }

    func testDateArgumentParsesZonesDaysAndRejectsOtherForms() throws {
        let zoned = try XCTUnwrap(DateArgument.parse("2026-10-07T09:00:00+02:00"))
        XCTAssertTrue(zoned.hasTime)
        XCTAssertEqual(zoned.date.timeIntervalSince1970, 1791356400)
        let local = try XCTUnwrap(DateArgument.parse("2026-10-07T09:00"))
        XCTAssertEqual(Calendar.current.component(.hour, from: local.date), 9)
        let day = try XCTUnwrap(DateArgument.parse("2026-10-07"))
        XCTAssertFalse(day.hasTime)
        XCTAssertEqual(DateText.stamp(day.date, hasTime: false), "2026-10-07")
        XCTAssertNil(DateArgument.parse("tomorrow"))
        XCTAssertNil(DateArgument.parse("07/10/2026"))
    }

    private func id(_ result: (code: Int32, out: String, err: String)) -> String { result.out.trimmingCharacters(in: .whitespacesAndNewlines) }

    func testFlagsTagsSectionsAndSubtasksRoundTrip() throws {
        _ = try run(["reminders", "access"])
        _ = try run(["reminders", "mklist", "Groceries"])
        let milk = try run(["reminders", "add", "Milk", "--list", "Groceries", "--flag", "--tag", "dairy, #urgent"])
        XCTAssertEqual(milk.code, 0, milk.err)
        let milkID = id(milk)
        let shown = try run(["reminders", "show", milkID])
        XCTAssertTrue(shown.out.contains("Flagged: true\nCompleted: false\nTags: #dairy #urgent"), shown.out)
        XCTAssertEqual(try run(["reminders", "ls", "--flagged"]).out, milkID + "\n")
        XCTAssertEqual(try run(["reminders", "ls", "--tag", "#DAIRY"]).out, milkID + "\n")
        XCTAssertEqual(try run(["reminders", "tags"]).out, "dairy\t1\nurgent\t1\n")
        XCTAssertEqual(try run(["reminders", "tags", milkID, "--remove", "urgent"]).code, 0)
        XCTAssertEqual(try run(["reminders", "tags", milkID]).out, "dairy\n")
        XCTAssertEqual(try run(["reminders", "tags", milkID, "--add", "dairy weekly"]).code, 0)
        XCTAssertEqual(try run(["reminders", "tags", milkID]).out, "dairy weekly\n")
        XCTAssertEqual(try run(["reminders", "unflag", milkID]).code, 0)
        XCTAssertEqual(try run(["reminders", "ls", "--flagged"]).out, "")
        XCTAssertEqual(try run(["reminders", "flag", milkID]).code, 0)
        XCTAssertEqual(try run(["reminders", "ls", "--flagged"]).out, milkID + "\n")
        XCTAssertEqual(try run(["reminders", "edit", milkID, "--no-flag"]).code, 0)
        XCTAssertEqual(try run(["reminders", "ls", "--flagged"]).out, "")
        let produce = try run(["reminders", "mksection", "Produce", "--list", "Groceries"])
        XCTAssertEqual(produce.code, 0, produce.err)
        XCTAssertEqual(id(produce).count, 36)
        let apples = id(try run(["reminders", "add", "Apples", "--list", "Groceries", "--section", "Produce"]))
        XCTAssertEqual(try run(["reminders", "sections", "--list", "Groceries"]).out, id(produce) + "\tProduce\n")
        XCTAssertEqual(try run(["reminders", "ls", "--list", "Groceries", "--section", String(id(produce).prefix(8))]).out, apples + "\n")
        XCTAssertTrue(try run(["reminders", "show", apples]).out.contains("List: Groceries\nSection: Produce\n"))
        XCTAssertEqual(try run(["reminders", "mv", milkID, "--section", "Produce"]).code, 0)
        XCTAssertEqual(try run(["reminders", "ls", "--list", "Groceries", "--section", "Produce"]).out.split(separator: "\n").count, 2)
        XCTAssertEqual(try run(["reminders", "edit", milkID, "--clear-section"]).code, 0)
        XCTAssertEqual(try run(["reminders", "ls", "--list", "Groceries", "--section", "Produce"]).out, apples + "\n")
        XCTAssertEqual(try run(["reminders", "renamesection", "Produce", "--list", "Groceries", "--name", "Fruit"]).code, 0)
        XCTAssertTrue(try run(["reminders", "show", apples]).out.contains("Section: Fruit\n"))
        XCTAssertEqual(try run(["reminders", "rmsection", "Fruit", "--list", "Groceries"]).code, 0)
        XCTAssertFalse(try run(["reminders", "show", apples]).out.contains("Section:"))
        XCTAssertEqual(try run(["reminders", "sections", "--list", "Groceries"]).err, "0 sections\n")
        let missing = try run(["reminders", "add", "Pears", "--list", "Groceries", "--section", "Nowhere"])
        XCTAssertEqual(missing.code, 1)
        XCTAssertTrue(missing.err.contains("Section not found in this list: Nowhere"), missing.err)
        let call = try run(["reminders", "add", "Call the store", "--parent", milkID])
        XCTAssertEqual(call.code, 0, call.err)
        XCTAssertEqual(try run(["reminders", "subtasks", milkID]).out, id(call) + "\n")
        XCTAssertTrue(try run(["reminders", "show", milkID]).out.contains("Subtask: \(id(call)) [ ] Call the store"))
        XCTAssertTrue(try run(["reminders", "show", id(call)]).out.contains("Parent: \(milkID)\n"))
        let object = try XCTUnwrap(try json(try run(["reminders", "show", id(call), "--json"]).out) as? [String: Any])
        XCTAssertEqual(object["parentID"] as? String, milkID)
        XCTAssertEqual(object["list"] as? String, "Groceries")
        XCTAssertEqual(try run(["reminders", "add", "x", "--parent", milkID, "--list", "Groceries"]).code, 64)
        XCTAssertEqual(try run(["reminders", "edit", id(call), "--clear-parent"]).code, 0)
        XCTAssertEqual(try run(["reminders", "subtasks", milkID]).err, "0 subtasks\n")
        XCTAssertEqual(try run(["reminders", "edit", id(call), "--parent", milkID]).code, 0)
        XCTAssertEqual(try run(["reminders", "rm", milkID]).code, 0)
        XCTAssertEqual(try run(["reminders", "show", id(call)]).code, 1, "subtasks go with the parent")
    }

    func testAttachmentsAreAddedListedExportedAndRemoved() throws {
        _ = try run(["reminders", "access"])
        _ = try run(["reminders", "mklist", "Home"])
        let reminder = id(try run(["reminders", "add", "Fix the fence", "--list", "Home"]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let picture = folder.appendingPathComponent("fence.png")
        try image.representation(using: .png, properties: [:])!.write(to: picture)
        let quote = folder.appendingPathComponent("quote.txt")
        try Data("fence quote".utf8).write(to: quote)
        let added = try run(["reminders", "attachments", "add", reminder, "--file", picture.path])
        XCTAssertEqual(added.code, 0, added.err)
        XCTAssertEqual(id(added), reminder)
        XCTAssertEqual(try run(["reminders", "attachments", "add", reminder, "--file", quote.path]).code, 0)
        XCTAssertEqual(try run(["reminders", "attachments", "add", reminder, "--url", "https://example.com/fence"]).code, 0)
        XCTAssertEqual(try run(["reminders", "attachments", "add", reminder, "--url", "not a url"]).code, 1)
        XCTAssertEqual(try run(["reminders", "attachments", "add", reminder]).code, 64)
        let listed = try run(["reminders", "attachments", "ls", reminder, "--json"])
        let data = try XCTUnwrap(try json(listed.out) as? [String: Any])
        let attachments = try XCTUnwrap(data["attachments"] as? [[String: Any]])
        XCTAssertEqual(attachments.map { $0["kind"] as? String }, ["image", "file", "url"])
        XCTAssertEqual(attachments[0]["width"] as? Int, 3)
        XCTAssertEqual(attachments[0]["height"] as? Int, 2)
        XCTAssertEqual(attachments[0]["uti"] as? String, "public.png")
        XCTAssertEqual(attachments[1]["size"] as? Int, 11)
        XCTAssertEqual(attachments[2]["url"] as? String, "https://example.com/fence")
        XCTAssertTrue(try run(["reminders", "show", reminder]).out.contains("Attachment: \(attachments[2]["id"]!) url https://example.com/fence"))
        let exportDir = folder.appendingPathComponent("saved")
        let exported = try run(["reminders", "attachments", "export", reminder, "--directory", exportDir.path])
        XCTAssertEqual(exported.code, 0, exported.err)
        let paths = exported.out.split(separator: "\n").map(String.init)
        XCTAssertEqual(paths.count, 2, "links are not exported")
        XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: paths[0]))), SHA256.hash(data: try Data(contentsOf: picture)))
        XCTAssertEqual(try run(["reminders", "attachments", "export", reminder, "--directory", exportDir.path]).code, 1, "export never overwrites")
        let one = folder.appendingPathComponent("copy.txt")
        XCTAssertEqual(id(try run(["reminders", "attachments", "export", reminder, "--attachment", String((attachments[1]["id"] as! String).prefix(8)), "--file", one.path])), one.path)
        XCTAssertEqual(try String(contentsOf: one), "fence quote")
        let removed = try run(["reminders", "attachments", "rm", reminder, "--attachment", attachments[0]["id"] as! String])
        XCTAssertEqual(removed.code, 0, removed.err)
        XCTAssertEqual(try run(["reminders", "attachments", "ls", reminder]).err, "2 attachments\n")
        XCTAssertEqual(try run(["reminders", "attachments", "rm", reminder, "--attachment", "nothing-here"]).code, 1)
        let blocked = try XCTUnwrap(attachments[1]["path"] as? String)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: blocked) }
        let denied = try run(["reminders", "attachments", "export", reminder, "--attachment", String((attachments[1]["id"] as! String).prefix(8)), "--file", folder.appendingPathComponent("denied.txt").path])
        XCTAssertEqual(denied.code, 1)
        XCTAssertTrue(denied.err.contains("macOS blocks this terminal application from reading the attachment file") && denied.err.contains("Full Disk Access"), denied.err)
    }
}
