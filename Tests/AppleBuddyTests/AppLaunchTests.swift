import CryptoKit
import Foundation
import XCTest
@testable import apple_buddy

final class AppLaunchTests: XCTestCase {
    private var directory: URL!
    private var storeFile: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("abdy-app-" + UUID().uuidString)
        storeFile = directory.appendingPathComponent("store.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var appDirectory: URL { directory.appendingPathComponent("app") }
    private var bundleExecutable: URL { appDirectory.appendingPathComponent("Abdy.app/Contents/MacOS/abdy") }

    private func run(_ arguments: [String], stdin: String = "", force: Bool = true) throws -> (code: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ".build/debug/abdy")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["ABDY_EVENT_STORE_FILE"] = storeFile.path
        environment["ABDY_APP_DIRECTORY"] = appDirectory.path
        if force { environment["ABDY_FORCE_APP"] = "1" }
        process.environment = environment
        let output = Pipe(), errors = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text, error)
    }

    private func id(_ result: (code: Int32, out: String, err: String)) -> String { result.out.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func sha(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }

    func testCommandRunsInsideTheAppAndKeepsStreamsAndExitCodesApart() throws {
        let version = try run(["version"])
        XCTAssertEqual(version.code, 0, version.err)
        XCTAssertEqual(version.out, "1.0.0\n")
        XCTAssertEqual(version.err, "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundleExecutable.path), "the app bundle is built on first use")
        _ = try run(["reminders", "access"])
        _ = try run(["reminders", "mklist", "Home"])
        let lists = try run(["reminders", "lists"])
        XCTAssertEqual(lists.code, 0, lists.err)
        XCTAssertTrue(lists.out.hasSuffix("\tiCloud\tHome\t0\n") || lists.out.contains("\tHome\t0\n"), lists.out)
        XCTAssertEqual(lists.err, "1 lists\n", "the summary goes to stderr, ids to stdout")
        let invalid = try run(["reminders", "add"])
        XCTAssertEqual(invalid.code, 64)
        XCTAssertEqual(invalid.out, "")
        XCTAssertTrue(invalid.err.contains("Provide the argument"), invalid.err)
        let missing = try run(["reminders", "show", "00000000-0000-0000-0000-000000000000"])
        XCTAssertEqual(missing.code, 1)
        XCTAssertTrue(missing.err.contains("Reminder not found"), missing.err)
    }

    func testArgumentsWithSpacesEmojiAndNegativeNumbersArriveUnchanged() throws {
        _ = try run(["reminders", "access"])
        _ = try run(["reminders", "mklist", "Café 🏠"])
        let added = try run(["reminders", "add", "Crème brûlée 🥛 and  two  spaces", "--list", "Café 🏠", "--notes=-5 degrees", "--leave=-33.95,151.03"])
        XCTAssertEqual(added.code, 0, added.err)
        let shown = try run(["reminders", "show", id(added)])
        XCTAssertTrue(shown.out.contains("Title: Crème brûlée 🥛 and  two  spaces\nList: Café 🏠\n"), shown.out)
        XCTAssertTrue(shown.out.contains("(-33.95, 151.03, 100 m)"), shown.out)
        XCTAssertTrue(shown.out.contains("\n\n-5 degrees"), shown.out)
    }

    func testStandardInputReachesTheCommand() throws {
        _ = try run(["reminders", "access"])
        _ = try run(["reminders", "mklist", "Home"])
        let first = id(try run(["reminders", "add", "First", "--list", "Home"]))
        let second = id(try run(["reminders", "add", "Second", "--list", "Home"]))
        let done = try run(["reminders", "done", "-"], stdin: first + "\n" + second + "\n")
        XCTAssertEqual(done.code, 0, done.err)
        XCTAssertEqual(done.out, first + "\n" + second + "\n")
        XCTAssertEqual(try run(["reminders", "ls", "--completed"]).out.split(separator: "\n").count, 2)
    }

    func testBundleIsRebuiltWhenItsExecutableDiffersFromTheRunningOne() throws {
        XCTAssertEqual(try run(["version"]).code, 0)
        let source = URL(fileURLWithPath: ".build/debug/abdy").resolvingSymlinksInPath()
        let plist = appDirectory.appendingPathComponent("Abdy.app/Contents/Info.plist")
        XCTAssertTrue(try String(contentsOf: plist, encoding: .utf8).contains(try sha(source)), "the bundle records the digest of the executable it was built from")
        let built = try FileManager.default.attributesOfItem(atPath: appDirectory.appendingPathComponent("Abdy.app").path)[.creationDate] as? Date
        XCTAssertEqual(try run(["version"]).code, 0)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: appDirectory.appendingPathComponent("Abdy.app").path)[.creationDate] as? Date, built, "an unchanged bundle is reused")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundleExecutable.path)
        try Data("not a program".utf8).write(to: bundleExecutable)
        let again = try run(["version"])
        XCTAssertEqual(again.code, 0, again.err)
        XCTAssertEqual(again.out, "1.0.0\n")
        XCTAssertNotEqual(try String(contentsOf: bundleExecutable, encoding: .isoLatin1), "not a program", "a broken bundle is rebuilt")
        XCTAssertEqual(AppBundle.codesign(["--verify", appDirectory.appendingPathComponent("Abdy.app").path]).status, 0)
        XCTAssertTrue(AppBundle.codesign(["-d", "-r-", appDirectory.appendingPathComponent("Abdy.app").path]).output.contains("designated => identifier \"com.noma4i.abdy\""))
    }

    func testHelpVersionAndTestStoresDoNotBuildTheApp() throws {
        for arguments in [["version"], ["reminders", "help"], ["notes", "help"], ["reminders", "access"]] {
            let result = try run(arguments, force: false)
            XCTAssertEqual(result.code, 0, "\(arguments): \(result.err)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: appDirectory.path), "no app for help, version or a test store")
    }
}

final class AppLaunchDecisionTests: XCTestCase {
    func testOnlyLiveNotesRemindersAndCalendarCommandsRunInTheApp() {
        let cases: [([String], [String: String], Bool)] = [
            (["notes", "ls"], [:], true), (["reminders", "lists"], [:], true), (["calendar", "events"], [:], true),
            (["--json", "notes", "ls"], [:], true), (["notes", "search", "invoice"], [:], true),
            (["version"], [:], false), (["mcp"], [:], false), ([], [:], false), (["--version"], [:], false),
            (["notes", "help"], [:], false), (["reminders", "add", "help"], [:], false), (["calendar", "--help"], [:], false),
            (["notes", "search", "invoice", "help"], [:], true),
            (["reminders", "lists"], ["ABDY_EVENT_STORE_FILE": "/tmp/x.json"], false),
            (["notes", "ls"], ["CFFIXED_USER_HOME": "/tmp/home"], false),
            (["notes", "ls"], ["ABDY_IN_APP": "1"], false),
            (["version"], ["ABDY_FORCE_APP": "1"], true),
            (["reminders", "lists"], ["ABDY_FORCE_APP": "1", "ABDY_EVENT_STORE_FILE": "/tmp/x.json"], true),
            (["reminders", "lists"], ["ABDY_FORCE_APP": "1", "ABDY_IN_APP": "1"], false),
        ]
        for (arguments, environment, expected) in cases {
            XCTAssertEqual(AppLaunch.shouldRunInApp(arguments: arguments, environment: environment), expected, "\(arguments) \(environment)")
        }
    }
}
