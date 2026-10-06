import CryptoKit
import Darwin
import Foundation

enum AppBundle {
    static let identifier = "com.noma4i.abdy"
    static let requirement = "designated => identifier \"\(identifier)\""

    static var directory: URL {
        if let path = ProcessInfo.processInfo.environment["ABDY_APP_DIRECTORY"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/apple-buddy")
    }

    static var bundle: URL { directory.appendingPathComponent("Abdy.app") }
    static var executable: URL { bundle.appendingPathComponent("Contents/MacOS/abdy") }

    static func infoPlist(sourceDigest: String) -> Data {
        let values: [String: Any] = [
            "AbdySourceSHA256": sourceDigest, "CFBundleIdentifier": identifier, "CFBundleExecutable": "abdy", "CFBundleName": "Abdy", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": AppleBuddy.releaseVersion, "LSUIElement": true,
            "NSRemindersFullAccessUsageDescription": "abdy reads and changes your reminders when you or an agent run abdy reminders commands.",
            "NSCalendarsFullAccessUsageDescription": "abdy reads and changes your calendar events when you or an agent run abdy calendar commands.",
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)) ?? Data()
    }

    static func digest(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isCurrent(plist: Data) -> Bool {
        (try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))) == plist && codesign(["--verify", bundle.path]).status == 0
    }

    @discardableResult
    static func codesign(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe
        do { try process.run() } catch { return (1, "cannot run codesign: \(error.localizedDescription)") }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    static func prepare() throws -> URL {
        guard let source = Bundle.main.executableURL?.resolvingSymlinksInPath() else { throw NotesError(description: "Cannot locate the abdy executable") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = open(directory.appendingPathComponent("Abdy.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw NotesError(description: "Cannot open the Abdy.app lock in \(directory.path): \(String(cString: strerror(errno)))") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw NotesError(description: "Cannot lock \(directory.path): \(String(cString: strerror(errno)))") }
        guard let sourceDigest = digest(source) else { throw NotesError(description: "Cannot read the abdy executable at \(source.path)") }
        let plist = infoPlist(sourceDigest: sourceDigest)
        if isCurrent(plist: plist) { return bundle }
        let staging = directory.appendingPathComponent("Abdy.app.\(getpid())")
        defer { try? FileManager.default.removeItem(at: staging) }
        try? FileManager.default.removeItem(at: staging)
        let macOS = staging.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: macOS.appendingPathComponent("abdy"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOS.appendingPathComponent("abdy").path)
        try plist.write(to: staging.appendingPathComponent("Contents/Info.plist"))
        let signed = codesign(["-s", "-", "--force", "-r=\(requirement)", staging.path])
        guard signed.status == 0 else { throw NotesError(description: "Cannot sign Abdy.app: \(signed.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        try? FileManager.default.removeItem(at: bundle)
        try FileManager.default.moveItem(at: staging, to: bundle)
        return bundle
    }
}
