import AppKit
import ArgumentParser
import Foundation
import NotesNative

func requestNotesSync() throws -> NSRunningApplication {
    guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Notes") else { throw NotesError(description: "Notes application not found, local changes remain saved") }
    try quitNotes(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes"))
    try autoreleasepool { try openLocalNotes(readOnly: false).pruneEmptyActivityEvents() }
    var configurationError: NSError?
    guard let configuration = NBNotesBackgroundConfiguration(&configurationError) else {
        throw configurationError ?? NotesError(description: "Background Notes launch is unavailable, local changes remain saved")
    }
    var completed = false
    var failure: Error?
    var launchedApplication: NSRunningApplication?
    NSWorkspace.shared.openApplication(at: application, configuration: configuration) { app, error in
        failure = error
        launchedApplication = app
        if app == nil && error == nil { failure = NotesError(description: "Notes did not start") }
        completed = true
    }
    let deadline = Date().addingTimeInterval(10)
    while !completed && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    guard completed else { throw NotesError(description: "Notes sync launch timed out, local changes remain saved") }
    if let failure { throw NotesError(description: "Notes sync launch failed, local changes remain saved: \(failure)") }
    guard let launchedApplication else { throw NotesError(description: "Notes did not start, local changes remain saved") }
    while !launchedApplication.isFinishedLaunching && Date() < deadline && !launchedApplication.isTerminated {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard launchedApplication.isFinishedLaunching && launchedApplication.activationPolicy == .prohibited else {
        try quitNotes([launchedApplication])
        throw NotesError(description: "Notes did not start as a background-only process, local changes remain saved")
    }
    return launchedApplication
}

func synchronizeNotes() throws -> [AnyHashable: Any] {
    var signalError: NSError?
    guard NBStartNotesSyncSignals(&signalError) else {
        throw signalError ?? NotesError(description: "Cannot register Notes sync interruption signals")
    }
    defer { NBStopNotesSyncSignals() }
    let application = try requestNotesSync()
    let result = Result { try waitForNotesSync(application) }
    do { try quitNotes([application]) }
    catch {
        if case .failure(let syncError) = result {
            FileHandle.standardError.write(Data("Notes shutdown failed: \(error)\n".utf8))
            throw syncError
        }
        throw error
    }
    _ = try result.get()
    let state = try autoreleasepool { try openLocalNotes(readOnly: true).cloudStatus() }
    guard state["pendingObjects"] as? Int == 0 else {
        throw NotesError(description: "Notes saved additional changes during shutdown, local changes remain saved and queued")
    }
    return state
}

func waitForNotesSync(_ application: NSRunningApplication) throws -> [AnyHashable: Any] {
    var deadline = Date().addingTimeInterval(120)
    var lastPending = Int.max
    while true {
        let interruption = NBNotesSyncInterruption()
        guard interruption == 0 else { throw NotesError(description: "Notes sync interrupted by signal \(interruption), local changes remain saved and queued") }
        guard !application.isTerminated else { throw NotesError(description: "Notes stopped before cloud acknowledgement, local changes remain saved and queued") }
        let state = try autoreleasepool { try openLocalNotes(readOnly: true).cloudStatus() }
        guard let pending = state["pendingObjects"] as? Int else { throw NotesError(description: "Cannot read cloud acknowledgement status, local changes remain saved") }
        if pending == 0 { return state }
        if pending < lastPending { lastPending = pending; deadline = Date().addingTimeInterval(120) }
        if Date() >= deadline { throw NotesError(description: "Cloud acknowledgement made no progress for 120 seconds, local changes remain saved and queued") }
        FileHandle.standardError.write(Data("Pending cloud objects: \(pending)\n".utf8))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }
}

struct Sync: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(abstract: "Synchronize saved changes with iCloud", discussion: """
        Writes save locally and do not sync. Run sync once after the last write.
        Notes stays hidden and exits when finished.
        Success confirms iCloud acknowledgement.
        The wait ends after 120 seconds without progress, changes stay saved for retry.
        pin and unpin sync on their own, their state lives in iCloud.

        EXAMPLES
          nb sync
          nb sync --status
        """)
    @Flag(help: "Read status without launching Notes") var status = false

    func run() throws {
        if status { try output.write(openLocalNotes(readOnly: true).cloudStatus()); return }
        try output.write(synchronizeNotes())
    }
}
