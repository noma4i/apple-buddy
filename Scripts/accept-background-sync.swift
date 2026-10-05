import AppKit
import Foundation
import CoreGraphics
import Darwin

do {
    guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").isEmpty else {
        throw NSError(domain: "accept-sync", code: 1, userInfo: [NSLocalizedDescriptionKey: "Notes must be closed before acceptance"])
    }
    let process = Process()
    let usage = NSError(domain: "accept-sync", code: 8, userInfo: [NSLocalizedDescriptionKey: "Usage: accept-background-sync [--interrupt=SIGNAL] NB_PATH [NB_ARGUMENTS]"])
    guard CommandLine.arguments.count > 1 else { throw usage }
    let interruptionArgument = CommandLine.arguments[1]
    let interrupted = interruptionArgument == "--interrupt" || interruptionArgument.hasPrefix("--interrupt=")
    let signalNumber = interruptionArgument == "--interrupt" ? SIGTERM : Int32(interruptionArgument.split(separator: "=").last ?? "")
    if interrupted && ![SIGINT, SIGTERM, SIGHUP].contains(signalNumber ?? 0) {
        throw NSError(domain: "accept-sync", code: 6, userInfo: [NSLocalizedDescriptionKey: "Only SIGINT, SIGTERM and SIGHUP are accepted"])
    }
    let argumentIndex = interrupted ? 2 : 1
    guard CommandLine.arguments.count > argumentIndex else { throw usage }
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[argumentIndex])
    process.arguments = Array(CommandLine.arguments.dropFirst(argumentIndex + 1))
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    var captured = Data()
    let reading = DispatchGroup()
    reading.enter()
    DispatchQueue.global().async {
        captured = output.fileHandleForReading.readDataToEndOfFile()
        reading.leave()
    }
    try process.run()
    var sawNotes = false
    var activatedNotes = false
    var foregroundWorker = false
    var visibleWindows = 0
    var signalSent = false
    let deadline = Date().addingTimeInterval(160)
    while process.isRunning && Date() < deadline {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").first {
            if !sawNotes { print("Notes worker observed: hidden=\(app.isHidden), policy=\(app.activationPolicy.rawValue)") }
            sawNotes = true
            foregroundWorker = foregroundWorker || app.activationPolicy != .prohibited
            guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                throw NSError(domain: "accept-sync", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot inspect visible windows"])
            }
            visibleWindows = max(visibleWindows, windows.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }.count)
            if interrupted && !signalSent {
                guard kill(process.processIdentifier, signalNumber!) == 0 else { throw NSError(domain: "accept-sync", code: 5) }
                signalSent = true
            }
        }
        activatedNotes = activatedNotes || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Notes"
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard !process.isRunning else {
        process.terminate()
        throw NSError(domain: "accept-sync", code: 2, userInfo: [NSLocalizedDescriptionKey: "CLI exceeded acceptance deadline"])
    }
    process.waitUntilExit()
    reading.wait()
    print(String(decoding: captured, as: UTF8.self))
    let count = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").count
    print("CLI exit: \(process.terminationStatus), Notes observed: \(sawNotes), activated: \(activatedNotes), foreground worker: \(foregroundWorker), visible windows: \(visibleWindows), Notes after exit: \(count)")
    let expectedExit = interrupted ? process.terminationStatus != 0 && signalSent : process.terminationStatus == 0
    guard expectedExit && sawNotes && !activatedNotes && !foregroundWorker && visibleWindows == 0 && count == 0 else {
        throw NSError(domain: "accept-sync", code: 3, userInfo: [NSLocalizedDescriptionKey: "Background-only sync acceptance failed"])
    }
    if !interrupted {
        let check = Process()
        check.executableURL = process.executableURL
        check.arguments = ["sync", "--status", "--json"]
        let statusOutput = Pipe()
        check.standardOutput = statusOutput
        try check.run()
        check.waitUntilExit()
        let state = try JSONSerialization.jsonObject(with: statusOutput.fileHandleForReading.readDataToEndOfFile()) as? [String: Any]
        print("Pending objects after Notes exit: \(state?["pendingObjects"] ?? "missing")")
        guard check.terminationStatus == 0 && state?["pendingObjects"] as? Int == 0 else {
            throw NSError(domain: "accept-sync", code: 7, userInfo: [NSLocalizedDescriptionKey: "Notes shutdown queued additional cloud writes"])
        }
    }
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
    exit(1)
}
