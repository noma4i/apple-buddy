import Darwin
import Dispatch
import Foundation

enum AppLaunch {
    static let groups: Set<String> = ["notes", "reminders", "calendar"]
    static let directEnvironment = ["ABDY_EVENT_STORE_FILE", "CFFIXED_USER_HOME", "ABDY_IN_APP"]
    static let exitFile = "ABDY_EXIT_FILE"
    static let pidFile = "ABDY_PID_FILE"
    nonisolated(unsafe) static var status: Int32 = 0

    static func shouldRunInApp(arguments: [String], environment: [String: String]) -> Bool {
        if environment["ABDY_IN_APP"] != nil { return false }
        if environment["ABDY_FORCE_APP"] == "1" { return true }
        if directEnvironment.contains(where: { environment[$0] != nil }) { return false }
        if arguments.prefix(3).contains("help") || arguments.contains("--help") || arguments.contains("-h") { return false }
        guard let group = arguments.first(where: { !$0.hasPrefix("-") }) else { return false }
        return groups.contains(group)
    }

    static func reportExitAtExit(environment: [String: String]) {
        guard environment[exitFile] != nil else { return }
        if let pid = environment[pidFile] { try? Data("\(getpid())".utf8).write(to: URL(fileURLWithPath: pid)) }
        atexit {
            fflush(nil)
            guard let path = ProcessInfo.processInfo.environment[AppLaunch.exitFile] else { return }
            try? Data("\(AppLaunch.status)".utf8).write(to: URL(fileURLWithPath: path + ".partial"))
            rename(path + ".partial", path)
        }
    }

    static func forwardedEnvironment(_ environment: [String: String]) -> [String] {
        environment.filter { $0.key.hasPrefix("ABDY_") || $0.key == "CFFIXED_USER_HOME" || $0.key == "TZ" }
            .filter { $0.key != "ABDY_FORCE_APP" }
            .sorted { $0.key < $1.key }.flatMap { ["--env", "\($0.key)=\($0.value)"] }
    }

    final class Tail {
        private let url: URL
        private let output: FileHandle
        private var offset: UInt64 = 0

        init(_ url: URL, to output: FileHandle) { self.url = url; self.output = output }

        func drain() {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
            offset += UInt64(data.count)
            try? output.write(contentsOf: data)
        }
    }

    static func run(arguments: [String], environment: [String: String]) throws -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let app = try AppBundle.prepare()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("abdy-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: work) }
        let input = work.appendingPathComponent("in"), out = work.appendingPathComponent("out"), err = work.appendingPathComponent("err")
        let exit = work.appendingPathComponent("exit"), pid = work.appendingPathComponent("pid"), launcherError = work.appendingPathComponent("launcher")
        try (arguments.contains("-") ? FileHandle.standardInput.readDataToEndOfFile() : Data()).write(to: input)
        for file in [out, err, launcherError] { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-n", "-g", "-j", "-a", app.path, "--stdin", input.path, "--stdout", out.path, "--stderr", err.path,
                              "--env", "ABDY_IN_APP=1", "--env", "\(exitFile)=\(exit.path)", "--env", "\(pidFile)=\(pid.path)"]
            + forwardedEnvironment(environment) + ["--args"] + arguments
        launcher.standardError = try FileHandle(forWritingTo: launcherError)
        launcher.standardOutput = FileHandle.nullDevice
        try launcher.run()
        let forwarders = [SIGINT, SIGTERM, SIGHUP].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                if let text = try? String(contentsOf: pid, encoding: .utf8), let target = Int32(text) { kill(target, number) }
            }
            source.resume()
            return source
        }
        defer { forwarders.forEach { $0.cancel() } }
        let stdout = Tail(out, to: .standardOutput), stderr = Tail(err, to: .standardError)
        var launcherDone: Date?
        while !FileManager.default.fileExists(atPath: exit.path) {
            stdout.drain()
            stderr.drain()
            if !launcher.isRunning {
                if launcher.terminationStatus != 0 {
                    let reason = (try? String(contentsOf: launcherError, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    throw NotesError(description: "macOS could not start Abdy.app: \(reason.isEmpty ? "open exited with \(launcher.terminationStatus)" : reason)")
                }
                launcherDone = launcherDone ?? Date()
                let alive = (try? String(contentsOf: pid, encoding: .utf8)).flatMap { Int32($0) }.map { kill($0, 0) == 0 } ?? false
                if !alive && Date().timeIntervalSince(launcherDone!) > (FileManager.default.fileExists(atPath: pid.path) ? 0.5 : 20) {
                    stdout.drain()
                    stderr.drain()
                    throw NotesError(description: "Abdy.app stopped without reporting an exit code, see ~/Library/Logs/DiagnosticReports")
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        stdout.drain()
        stderr.drain()
        guard let text = try? String(contentsOf: exit, encoding: .utf8), let code = Int32(text) else { throw NotesError(description: "Abdy.app reported an invalid exit code") }
        return code
    }
}
