import Foundation
import XCTest
@testable import apple_buddy

final class CalendarTests: XCTestCase {
    private var storeFile: URL!

    override func setUpWithError() throws {
        storeFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        XCTAssertEqual(try run(["calendar", "access"]).code, 0)
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
    private func id(_ result: (code: Int32, out: String, err: String)) -> String { result.out.trimmingCharacters(in: .whitespacesAndNewlines) }

    func testCalendarsListCreateRenameRemoveAndRefuseReadOnly() throws {
        let work = id(try run(["calendar", "mkcal", "Work"]))
        XCTAssertEqual(work.count, 36)
        _ = try run(["calendar", "mkcal", "Holidays", "--source", "Subscribed Calendars"])
        let listed = try run(["calendar", "calendars"])
        let rows = listed.out.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(rows.map { $0[3] }, ["Work", "Holidays"])
        XCTAssertEqual(rows.map { $0[4] }, ["", "RO"])
        XCTAssertEqual(rows.map { $0[2] }, ["local", "subscription"])
        XCTAssertEqual(listed.err, "2 calendars\n")
        let objects = try XCTUnwrap(try json(try run(["calendar", "calendars", "--json"]).out) as? [[String: Any]])
        XCTAssertEqual(objects.first?["isDefault"] as? Bool, true)
        XCTAssertEqual(objects.last?["readOnly"] as? Bool, true)
        let refused = try run(["calendar", "add", "Xmas", "--calendar", "Holidays", "--start", "2026-12-25"])
        XCTAssertEqual(refused.code, 1)
        XCTAssertTrue(refused.err.contains("Calendar Holidays is read-only and cannot hold new events"), refused.err)
        XCTAssertTrue(try run(["calendar", "rmcal", "Holidays"]).err.contains("Calendar Holidays is read-only and cannot be removed"))
        XCTAssertEqual(try run(["calendar", "renamecal", String(work.prefix(8)), "--name", "Clients"]).code, 0)
        XCTAssertEqual(try run(["calendar", "rmcal", "Clients"]).code, 0)
        XCTAssertEqual(try run(["calendar", "calendars"]).err, "1 calendars\n")
        let missing = try run(["calendar", "mkcal", "X", "--source", "Nowhere"])
        XCTAssertTrue(missing.err.contains("Source not found: Nowhere. Use a name or id from abdy calendar calendars --json"), missing.err)
    }

    func testEventsAddListShowEditMoveAndRemove() throws {
        _ = try run(["calendar", "mkcal", "Personal"])
        _ = try run(["calendar", "mkcal", "Work"])
        let dentist = try run(["calendar", "add", "Dentist", "--calendar", "Personal", "--start", "2026-10-09T14:00", "--duration", "45", "--alarm", "60", "--location", "Main St", "--notes", "bring card"])
        XCTAssertEqual(dentist.code, 0, dentist.err)
        let dentistID = id(dentist)
        XCTAssertTrue(dentist.err.hasPrefix("calendar add: Dentist"), dentist.err)
        let holiday = try run(["calendar", "add", "Holiday", "--start", "2026-12-24", "--end", "2026-12-26", "--all-day"])
        XCTAssertEqual(holiday.code, 0, holiday.err)
        let week = try run(["calendar", "events", "--from", "2026-10-05", "--to", "2026-10-12", "--long"])
        XCTAssertEqual(week.code, 0, week.err)
        let rows = week.out.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0][0], dentistID)
        XCTAssertTrue(rows[0][1].hasPrefix("2026-10-09T14:00:00"), rows[0][1])
        XCTAssertTrue(rows[0][2].hasPrefix("2026-10-09T14:45:00"), rows[0][2])
        XCTAssertEqual(rows[0][3], "Personal")
        XCTAssertEqual(rows[0][4], "Dentist")
        XCTAssertEqual(week.err, "1 events\n")
        let xmas = try run(["calendar", "events", "--from", "2026-12-20", "--to", "2026-12-31", "--long"])
        let xmasRow = xmas.out.split(separator: "\n").first!.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(Array(xmasRow[1...2]), ["2026-12-24", "2026-12-26"], "all-day end is the last day")
        let shown = try run(["calendar", "show", String(dentistID.prefix(8))])
        XCTAssertTrue(shown.out.contains("Title: Dentist\nCalendar: Personal\nStart: 2026-10-09T14:00:00"), shown.out)
        XCTAssertTrue(shown.out.contains("Location: Main St\nAlarms: 60 min before\n\nbring card"), shown.out)
        let edited = try run(["calendar", "edit", dentistID, "--title", "Dentist, moved", "--start", "2026-10-10T15:00", "--clear-alarms"])
        XCTAssertEqual(edited.code, 0, edited.err)
        let object = try XCTUnwrap(try json(try run(["calendar", "show", dentistID, "--json"]).out) as? [String: Any])
        XCTAssertEqual(object["title"] as? String, "Dentist, moved")
        XCTAssertTrue((object["start"] as? String ?? "").hasPrefix("2026-10-10T15:00:00"))
        XCTAssertTrue((object["end"] as? String ?? "").hasPrefix("2026-10-10T15:45:00"), "duration kept: \(object["end"] ?? "")")
        XCTAssertEqual((object["alarms"] as? [Int])?.count, 0)
        XCTAssertEqual(try run(["calendar", "events", "--from", "2026-10-05", "--to", "2026-10-12", "--search", "dentist", "--calendar", "Work"]).err, "0 events\n")
        let moved = try run(["calendar", "mv", dentistID, "--calendar", "Work"])
        XCTAssertEqual(moved.code, 0, moved.err)
        XCTAssertEqual(try run(["calendar", "events", "--from", "2026-10-05", "--to", "2026-10-12", "--search", "dentist", "--calendar", "Work"]).out, dentistID + "\n")
        XCTAssertEqual(try run(["calendar", "rm", dentistID]).out, dentistID + "\n")
        XCTAssertEqual(try run(["calendar", "events", "--from", "2026-10-05", "--to", "2026-10-12"]).err, "0 events\n")
        XCTAssertEqual(try run(["calendar", "add", "x", "--start", "2026-10-09T14:00", "--end", "2026-10-09T13:00"]).code, 64)
        XCTAssertEqual(try run(["calendar", "add", "x"]).code, 64, "--start is required")
    }

    func testRepeatingEventsExpandAndNeedOccurrenceAndSpan() throws {
        _ = try run(["calendar", "mkcal", "Work"])
        let standup = try run(["calendar", "add", "Standup", "--calendar", "Work", "--start", "2026-10-06T09:30", "--duration", "15", "--repeat", "weekly", "--count", "4"])
        XCTAssertEqual(standup.code, 0, standup.err)
        let standupID = id(standup)
        let month = try run(["calendar", "events", "--from", "2026-10-01", "--to", "2026-11-30", "--json"])
        let occurrences = try XCTUnwrap(try json(month.out) as? [[String: Any]])
        XCTAssertEqual(occurrences.count, 4)
        XCTAssertEqual(Set(occurrences.compactMap { $0["id"] as? String }), [standupID])
        let second = try XCTUnwrap(occurrences[1]["occurrence"] as? String)
        XCTAssertTrue(second.hasPrefix("2026-10-13T09:30:00"), second)
        let plain = try run(["calendar", "edit", standupID, "--title", "Sync"])
        XCTAssertEqual(plain.code, 64)
        XCTAssertTrue(plain.err.contains("this event repeats, pass --occurrence"), plain.err)
        XCTAssertEqual(try run(["calendar", "edit", standupID, "--occurrence", second, "--title", "Sync"]).code, 64, "--span is required")
        let one = try run(["calendar", "edit", standupID, "--occurrence", second, "--span", "this", "--title", "Sync", "--start", "2026-10-13T10:00", "--duration", "15"])
        XCTAssertEqual(one.code, 0, one.err)
        let afterOne = try XCTUnwrap(try json(try run(["calendar", "events", "--from", "2026-10-01", "--to", "2026-11-30", "--json"]).out) as? [[String: Any]])
        XCTAssertEqual(afterOne.map { $0["title"] as? String }, ["Standup", "Sync", "Standup", "Standup"])
        XCTAssertTrue((afterOne[1]["start"] as? String ?? "").hasPrefix("2026-10-13T10:00:00"))
        let third = try XCTUnwrap(occurrences[2]["occurrence"] as? String)
        let future = try run(["calendar", "edit", standupID, "--occurrence", third, "--span", "future", "--start", "2026-10-20T11:00", "--duration", "30"])
        XCTAssertEqual(future.code, 0, future.err)
        let afterFuture = try XCTUnwrap(try json(try run(["calendar", "events", "--from", "2026-10-01", "--to", "2026-11-30", "--json"]).out) as? [[String: Any]])
        XCTAssertEqual(afterFuture.count, 4)
        XCTAssertTrue((afterFuture[2]["start"] as? String ?? "").hasPrefix("2026-10-20T11:00:00"), "\(afterFuture[2])")
        XCTAssertNotEqual(afterFuture[2]["id"] as? String, standupID, "future edits start a new series")
        let removeAll = try run(["calendar", "rm", standupID])
        XCTAssertEqual(removeAll.code, 64)
        XCTAssertTrue(removeAll.err.contains("a repeating event needs --occurrence"), removeAll.err)
        let first = try XCTUnwrap(occurrences[0]["occurrence"] as? String)
        XCTAssertEqual(try run(["calendar", "rm", standupID, "--occurrence", first, "--span", "this"]).code, 0)
        let afterRemove = try XCTUnwrap(try json(try run(["calendar", "events", "--from", "2026-10-01", "--to", "2026-11-30", "--json"]).out) as? [[String: Any]])
        XCTAssertEqual(afterRemove.count, 3)
        XCTAssertEqual(afterRemove.first?["title"] as? String, "Sync")
    }
}
