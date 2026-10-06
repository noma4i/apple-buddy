import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import NotesNative
import SQLite3

struct Backup: ParsableCommand {
    @OptionGroup var output: OutputOptions
    @Argument(help: "New backup directory to create") var destination: String
    static let configuration = CommandConfiguration(
        abstract: "Back up the local Notes database and attachment files",
        discussion: """
        Copies local data without changing Notes or iCloud. An attachment without a local file fails the backup.
        With --skip-missing the backup goes on without such attachments, lists them in stderr,
        in skippedAttachments of the JSON result and in the manifest.
        The destination must be new and outside Notes. Files stay private to their owner.

        EXAMPLES
          nb backup ~/Backups/notes-2026-10-05
          nb backup ~/Backups/notes-2026-10-05 --skip-missing
        """
    )
    @Flag(help: "Back up without attachments that have no local file and list them") var skipMissing = false

    func run() throws {
        let source = notesDirectory()
        let target = URL(fileURLWithPath: destination).standardizedFileURL
        try validateBackupDestination(target, excluding: source)
        let store = try NBNotes(url: source.appendingPathComponent("NoteStore.sqlite"), readOnly: true)
        let attachments = try store.backupAttachments()
        guard let required = attachments["paths"] as? [String], let missing = attachments["missing"] as? [[String: String]] else { throw NotesError(description: "Notes returned invalid attachment data") }
        if let first = missing.first, !skipMissing {
            throw NotesError(description: "Attachment \(first["attachment"] ?? "") (\(first["type"] ?? "")), note \(first["note"] ?? ""), has no local file, no complete backup created. Use --skip-missing to back up the rest")
        }
        guard required.allSatisfy({ isWithin(URL(fileURLWithPath: $0), source) }) else {
            throw NotesError(description: "An attachment is outside the Notes directory, no backup created")
        }
        let skipped = missing.map { NotesBackupSkippedAttachment(attachment: $0["attachment"] ?? "", note: $0["note"] ?? "", type: $0["type"] ?? "") }
        let manifest = try createNotesBackup(from: source, to: target, skipping: skipped)
        for item in skipped { output.summary("Skipped attachment \(item.attachment) (\(item.type)), note \(item.note), no local file") }
        let result = try JSONSerialization.jsonObject(with: JSONEncoder().encode(skipped))
        try output.write(["path": target.path, "files": manifest.files.count, "bytes": manifest.files.reduce(Int64(0)) { $0 + $1.bytes }, "skippedAttachments": result], text: target.path)
    }
}

struct Restore: ParsableCommand {
    @OptionGroup var output: OutputOptions
    @Argument(help: "Backup directory to read") var backup: String
    @Option(help: "New isolated directory, never the working Notes directory") var to: String
    static let configuration = CommandConfiguration(
        abstract: "Restore a backup into a new isolated directory",
        discussion: """
        Verifies every file before restoring. Does not replace Notes or change iCloud.
        The restored directory is a recovery copy, not imported notes in the Notes app.
        Never move its database over your working iCloud database.

        EXAMPLE
          nb restore ~/Backups/notes-2026-10-05 --to ~/Recovered/notes
        """
    )

    func run() throws {
        let source = URL(fileURLWithPath: backup).standardizedFileURL
        let target = URL(fileURLWithPath: to).standardizedFileURL
        try validateBackupDestination(target, excluding: source)
        let manifest = try readNotesBackup(source)
        try publishDirectory(target) { staging in
            try copyBackupFiles(manifest, from: source.appendingPathComponent("data"), to: staging)
            try verifyBackupFiles(manifest, at: staging)
        }
        try output.write(["path": target.path, "files": manifest.files.count, "isolated": true], text: target.path)
    }
}

struct NotesBackupFile: Codable, Equatable {
    let path: String
    let bytes: Int64
    let sha256: String
}

struct NotesBackupSkippedAttachment: Codable, Equatable {
    let attachment: String
    let note: String
    let type: String
}

struct NotesBackupManifest: Codable {
    let version: Int
    let createdAt: String
    let macOS: String
    let directories: [String]
    let files: [NotesBackupFile]
    var skippedAttachments: [NotesBackupSkippedAttachment]? = nil
}

func notesDirectory() -> URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/group.com.apple.notes")
}

private func isWithin(_ url: URL, _ directory: URL) -> Bool {
    let child = url.resolvingSymlinksInPath().standardizedFileURL.path
    let parent = directory.resolvingSymlinksInPath().standardizedFileURL.path
    return child == parent || child.hasPrefix(parent + "/")
}

private func validateBackupDestination(_ target: URL, excluding source: URL) throws {
    guard !isWithin(target, source), !isWithin(source, target), !isWithin(target, notesDirectory()) else {
        throw NotesError(description: "Destination must be outside Notes and the source directory")
    }
    guard !FileManager.default.fileExists(atPath: target.path), (try? FileManager.default.attributesOfItem(atPath: target.path)) == nil else {
        throw NotesError(description: "destination already exists: \(target.path)")
    }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path, isDirectory: &directory), directory.boolValue else {
        throw NotesError(description: "Destination parent directory does not exist")
    }
}

private func publishDirectory(_ target: URL, write: (URL) throws -> Void) throws {
    let staging = target.deletingLastPathComponent().appendingPathComponent(".nb-" + UUID().uuidString)
    guard mkdir(staging.path, 0o700) == 0 else { throw NotesError(description: String(cString: strerror(errno))) }
    do {
        try write(staging)
        guard renamex_np(staging.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            throw NotesError(description: "Cannot publish backup or restore without replacing data: \(String(cString: strerror(errno)))")
        }
    } catch {
        do { try FileManager.default.removeItem(at: staging) }
        catch let cleanup { throw NotesError(description: "\(error). Incomplete copy remains at \(staging.path): \(cleanup)") }
        throw error
    }
}

private func tree(_ directory: URL, excluding: Set<String> = []) throws -> (directories: [String], files: [String]) {
    let rootAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    guard rootAttributes[.type] as? FileAttributeType == .typeDirectory else { throw NotesError(description: "Source must be a real directory") }
    guard let physical = realpath(directory.path, nil) else { throw NotesError(description: "Cannot resolve source directory") }
    let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
    free(physical)
    var failure: Error?
    guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, error in failure = error; return false }) else {
        throw NotesError(description: "Cannot read source directory")
    }
    var directories: [String] = [], files: [String] = []
    for case let url as URL in items {
        guard url.path.hasPrefix(root.path + "/") else { throw NotesError(description: "File is outside the source directory") }
        let path = String(url.path.dropFirst(root.path.count + 1))
        if excluding.contains(path) { items.skipDescendants(); continue }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        switch attributes[.type] as? FileAttributeType {
        case .typeDirectory: directories.append(path)
        case .typeRegular: files.append(path)
        default: throw NotesError(description: "Unsupported file or symbolic link: \(path)")
        }
    }
    if let failure { throw failure }
    return (directories.sorted(), files.sorted())
}

private func fingerprint(_ url: URL, path: String) throws -> NotesBackupFile {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256(), bytes: Int64 = 0
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
        hash.update(data: data)
        bytes += Int64(data.count)
    }
    return NotesBackupFile(path: path, bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
}

func createNotesBackup(from source: URL, to target: URL, skipping skipped: [NotesBackupSkippedAttachment] = []) throws -> NotesBackupManifest {
    let excluded: Set<String> = ["NoteStore.sqlite-wal", "NoteStore.sqlite-shm", "NoteStore.sqlite-journal", "com.apple.notes.databaseopen.lock", "SharingExtensionWriteLock", "Library", "tmp"]
    let original = try tree(source, excluding: excluded)
    guard original.files.contains("NoteStore.sqlite") else { throw NotesError(description: "NoteStore.sqlite not found") }
    var connection: OpaquePointer?
    guard sqlite3_open_v2(source.appendingPathComponent("NoteStore.sqlite").path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        if let connection { sqlite3_close(connection) }
        throw NotesError(description: "Cannot open Notes database read-only")
    }
    defer { sqlite3_close(connection) }
    let version = try sqliteScalar(connection, "PRAGMA data_version")
    var result: NotesBackupManifest!
    try publishDirectory(target) { staging in
        let data = staging.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for path in original.directories {
            try FileManager.default.createDirectory(at: data.appendingPathComponent(path), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        var files: [NotesBackupFile] = []
        for path in original.files {
            let input = source.appendingPathComponent(path), output = data.appendingPathComponent(path)
            if path == "NoteStore.sqlite" {
                let descriptor = open(output.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
                guard descriptor >= 0 else { throw NotesError(description: "Cannot create backup database") }
                close(descriptor)
                try SnapshotDatabase().copyDatabase(from: input, to: output)
                try checkDatabase(output)
            } else {
                let before = try fingerprint(input, path: path)
                try FileManager.default.copyItem(at: input, to: output)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                guard try fingerprint(output, path: path) == before else { throw NotesError(description: "Source changed during backup: \(path)") }
            }
            files.append(try fingerprint(output, path: path))
        }
        let final = try tree(source, excluding: excluded)
        guard original.files == final.files, original.directories == final.directories else { throw NotesError(description: "Source file list changed during backup") }
        for file in files where file.path != "NoteStore.sqlite" {
            guard try fingerprint(source.appendingPathComponent(file.path), path: file.path) == file else { throw NotesError(description: "Source changed during backup: \(file.path)") }
        }
        guard try sqliteScalar(connection, "PRAGMA data_version") == version else { throw NotesError(description: "Notes changed during backup, retry when idle") }
        result = NotesBackupManifest(version: 1, createdAt: ISO8601DateFormatter().string(from: Date()), macOS: ProcessInfo.processInfo.operatingSystemVersionString, directories: original.directories, files: files, skippedAttachments: skipped.isEmpty ? nil : skipped)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifest = staging.appendingPathComponent("manifest.json")
        try encoder.encode(result).write(to: manifest, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
        _ = try readNotesBackup(staging)
    }
    return result
}

private func safeBackupPath(_ path: String) -> Bool {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}

private func readNotesBackup(_ root: URL) throws -> NotesBackupManifest {
    let files = try tree(root)
    guard files.files.contains("manifest.json"), files.directories.contains("data") else { throw NotesError(description: "Not a nb backup") }
    let manifest = try JSONDecoder().decode(NotesBackupManifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
    let paths = manifest.files.map(\.path)
    guard manifest.version == 1, paths.contains("NoteStore.sqlite"), Set(paths).count == paths.count,
          Set(manifest.directories).count == manifest.directories.count,
          (paths + manifest.directories).allSatisfy(safeBackupPath), manifest.files.allSatisfy({ $0.bytes >= 0 && $0.sha256.count == 64 }) else {
        throw NotesError(description: "Invalid backup manifest or unsupported version")
    }
    guard files.files.sorted() == (["manifest.json"] + paths.map { "data/" + $0 }).sorted(),
          files.directories.sorted() == (["data"] + manifest.directories.map { "data/" + $0 }).sorted() else {
        throw NotesError(description: "Backup file list does not match the manifest")
    }
    try verifyBackupFiles(manifest, at: root.appendingPathComponent("data"))
    return manifest
}

private func verifyBackupFiles(_ manifest: NotesBackupManifest, at root: URL) throws {
    for file in manifest.files {
        guard try fingerprint(root.appendingPathComponent(file.path), path: file.path) == file else { throw NotesError(description: "Backup checksum mismatch: \(file.path)") }
    }
    try checkDatabase(root.appendingPathComponent("NoteStore.sqlite"))
}

private func copyBackupFiles(_ manifest: NotesBackupManifest, from source: URL, to target: URL) throws {
    for path in manifest.directories.sorted() {
        try FileManager.default.createDirectory(at: target.appendingPathComponent(path), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    for file in manifest.files {
        let destination = target.appendingPathComponent(file.path)
        try FileManager.default.copyItem(at: source.appendingPathComponent(file.path), to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}

private func sqliteScalar(_ database: OpaquePointer?, _ sql: String) throws -> String {
    var statement: OpaquePointer?
    defer { sqlite3_finalize(statement) }
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
          sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
        throw NotesError(description: "Cannot check database consistency")
    }
    return String(cString: value)
}

private func checkDatabase(_ url: URL) throws {
    var connection: OpaquePointer?
    defer { if let connection { sqlite3_close(connection) } }
    guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
          try sqliteScalar(connection, "PRAGMA integrity_check") == "ok" else {
        throw NotesError(description: "Database integrity check failed")
    }
}
