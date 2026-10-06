import ArgumentParser
import Darwin
import Foundation
import SQLite3

struct SnapshotDatabase: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "snapshot-db",
        abstract: "Copy a database, including committed WAL data, for offline inspection",
        discussion: """
        Opens the source read-only and uses the SQLite backup API.
        The destination must not exist. The copy is readable only by its owner.
        This copies database records, not attachment files. It is not a full Notes backup
        and must not be restored over a live iCloud database.
        Reading the default Notes database may require Full Disk Access.
        """
    )

    @Argument(help: "New SQLite file to create") var destination: String
    @Option(help: "Source database, defaults to this user's Notes database") var database: String?

    func run() throws {
        let source = database.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Group Containers/group.com.apple.notes/NoteStore.sqlite")
        let target = URL(fileURLWithPath: destination).standardizedFileURL
        let descriptor = open(target.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else {
            let reason = errno == EEXIST ? "destination already exists" : String(cString: strerror(errno))
            throw NotesError(description: "\(reason): \(target.path)")
        }
        close(descriptor)
        do {
            try copyDatabase(from: source, to: target)
        } catch {
            do {
                try FileManager.default.removeItem(at: target)
            } catch let removalError {
                throw NotesError(description: "\(error). Could not remove incomplete snapshot: \(removalError)")
            }
            throw error
        }
        try output.write(["path": target.path], text: target.path)
    }

    func copyDatabase(from source: URL, to target: URL) throws {
        let result = Result { try writeDatabaseCopy(from: source, to: target) }
        for suffix in ["-shm", "-wal", "-journal"] {
            let sidecar = URL(fileURLWithPath: target.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        }
        try result.get()
    }

    private func writeDatabaseCopy(from source: URL, to target: URL) throws {
        var input: OpaquePointer?
        var output: OpaquePointer?
        defer {
            if let output { sqlite3_close(output) }
            if let input { sqlite3_close(input) }
        }
        guard sqlite3_open_v2(source.path, &input, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw databaseError(input)
        }
        guard sqlite3_open_v2(target.path, &output, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw databaseError(output)
        }
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
            throw databaseError(output)
        }
        let status = sqlite3_backup_step(backup, -1)
        let finishStatus = sqlite3_backup_finish(backup)
        guard status == SQLITE_DONE, finishStatus == SQLITE_OK else {
            throw databaseError(output)
        }
        guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else {
            throw databaseError(output)
        }
    }

    private func databaseError(_ database: OpaquePointer?) -> NotesError {
        NotesError(description: String(cString: sqlite3_errmsg(database)))
    }
}
