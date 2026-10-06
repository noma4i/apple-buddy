import ArgumentParser
import CryptoKit
import Foundation
import NotesNative
import SQLite3

struct BearNote {
    let key: String
    let identifier: String
    let title: String
    var text: String
    var tags: [String] = []
    var files: [String] = []

    var destination: String {
        tags.sorted {
            let left = $0.split(separator: "/").count
            let right = $1.split(separator: "/").count
            return left == right ? $0 < $1 : left > right
        }.first ?? "Untagged"
    }

    var notesIdentifier: String {
        let bytes = Array(SHA256.hash(data: Data("nb:bear:\(identifier)".utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }
}

func readBearNotes(at directory: URL) throws -> [BearNote] {
    var database: OpaquePointer?
    guard sqlite3_open_v2(directory.appendingPathComponent("database.sqlite").path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
        if let database { sqlite3_close(database) }
        throw NotesError(description: "Cannot open Bear database read-only")
    }
    defer { sqlite3_close(database) }
    func rows(_ sql: String) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else { throw NotesError(description: String(cString: sqlite3_errmsg(database))) }
        defer { sqlite3_finalize(statement) }
        var result: [[String]] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            result.append((0..<sqlite3_column_count(statement)).map { index in
                sqlite3_column_text(statement, index).map { String(cString: $0) } ?? ""
            })
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw NotesError(description: String(cString: sqlite3_errmsg(database))) }
        return result
    }
    _ = try rows("BEGIN")
    let active = "COALESCE(ZTRASHED,0)=0 AND COALESCE(ZPERMANENTLYDELETED,0)=0"
    let source = try rows("SELECT Z_PK,ZUNIQUEIDENTIFIER,ZTITLE,ZTEXT,COALESCE(ZENCRYPTED,0) FROM ZSFNOTE WHERE \(active) ORDER BY Z_PK")
    var notes = source.map { BearNote(key: $0[0], identifier: $0[1], title: $0[2], text: $0[3]) }
    guard source.allSatisfy({ $0[4] == "0" }) else { throw NotesError(description: "Bear has encrypted notes, refusing an incomplete import") }
    let positions = Dictionary(uniqueKeysWithValues: notes.enumerated().map { ($0.element.key, $0.offset) })
    for row in try rows("SELECT r.Z_5NOTES,t.ZTITLE FROM Z_5TAGS r JOIN ZSFNOTETAG t ON t.Z_PK=r.Z_13TAGS ORDER BY t.ZTITLE") {
        if let index = positions[row[0]] { notes[index].tags.append(row[1]) }
    }
    for row in try rows("SELECT ZNOTE,ZUNIQUEIDENTIFIER,ZFILENAME,COALESCE(ZDOWNLOADED,0),COALESCE(ZENCRYPTED,0) FROM ZSFNOTEFILE WHERE COALESCE(ZUNUSED,0)=0 AND COALESCE(ZPERMANENTLYDELETED,0)=0 ORDER BY ZNOTE,ZINDEX,Z_PK") {
        guard let index = positions[row[0]] else { continue }
        guard row[1] == URL(fileURLWithPath: row[1]).lastPathComponent, row[2] == URL(fileURLWithPath: row[2]).lastPathComponent else {
            throw NotesError(description: "Invalid Bear attachment path")
        }
        let candidates = ["Note Files", "Note Images"].map { directory.appendingPathComponent("Local Files/\($0)").appendingPathComponent(row[1]).appendingPathComponent(row[2]).standardizedFileURL }
        let available = candidates.filter { FileManager.default.isReadableFile(atPath: $0.path) }
        guard row[3] == "1", row[4] == "0", available.count == 1, let file = available.first else { throw NotesError(description: "Bear attachment unavailable, ambiguous or encrypted: \(row[1])/\(row[2])") }
        notes[index].files.append(file.path)
    }
    _ = try rows("COMMIT")
    return notes
}

func bearMarkdown(_ note: BearNote) -> String {
    var text = note.text
    let tasks = try! NSRegularExpression(pattern: "(?m)^([ \\t]*)[-*+] \\[([ xX])\\] ")
    let original = text as NSString
    let matches = tasks.matches(in: text, range: NSRange(location: 0, length: original.length))
    for (index, match) in matches.enumerated().reversed() {
        let checked = original.substring(with: match.range(at: 2)).lowercased() == "x"
        let indent = original.substring(with: match.range(at: 1))
        let token = "NBTODO\(checked ? 1 : 0)_\(note.notesIdentifier.replacingOccurrences(of: "-", with: ""))_\(index) "
        text = (text as NSString).replacingCharacters(in: match.range, with: indent + "- " + token)
    }
    for tag in note.tags.sorted(by: { $0.count > $1.count }) {
        let escaped = NSRegularExpression.escapedPattern(for: tag)
        text = text.replacingOccurrences(of: "(?<!\\S)#\(escaped)#?(?=\\s|$)", with: "", options: .regularExpression)
    }
    for (index, path) in note.files.enumerated() {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let encoded = NSRegularExpression.escapedPattern(for: name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)
        let token = "NBATTACHMENT\(index)_\(note.notesIdentifier.replacingOccurrences(of: "-", with: ""))"
        text = text.replacingOccurrences(of: "!?\\[\\[[^\\]]*\(escaped)\\]\\]|!?\\[[^\\]]*\\]\\((?:\(escaped)|\(encoded))\\)(?:<!--.*?-->)?", with: token, options: .regularExpression)
    }
    return text
}

func bearReferences(_ note: BearNote) throws -> [String] {
    let pattern = try NSRegularExpression(pattern: "(?<!!)\\[\\[([^\\]]+)\\]\\]")
    let text = note.text as NSString
    return pattern.matches(in: note.text, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range(at: 1)) }
}

func fileDigest(_ path: String) throws -> String {
    let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    defer { try? input.close() }
    var hash = SHA256()
    while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func renderBearHTML(_ text: String, pandoc: String, directory: URL) throws -> String {
    let input = directory.appendingPathComponent("note.md")
    let output = directory.appendingPathComponent("note.html")
    try text.write(to: input, atomically: true, encoding: .utf8)
    let conversion = Process()
    conversion.executableURL = URL(fileURLWithPath: pandoc)
    conversion.arguments = ["--from=markdown+pipe_tables+raw_html-yaml_metadata_block-smart", "--to=html", "--wrap=none", input.path, "--output", output.path]
    try conversion.run()
    conversion.waitUntilExit()
    guard conversion.terminationStatus == 0 else { throw NotesError(description: "pandoc failed with exit code \(conversion.terminationStatus)") }
    return try String(contentsOf: output, encoding: .utf8)
}

func verifyBearNote(_ note: BearNote, state: [AnyHashable: Any], digests: [String: String]) throws -> Int {
    guard state["folderPath"] as? String == note.destination else { throw NotesError(description: "Imported folder differs for \(note.identifier): \(state["folderPath"] ?? "missing") instead of \(note.destination)") }
    let attachments = (state["attachments"] as? [[String: Any]] ?? []).filter { ($0["type"] as? String) != "com.apple.notes.table" }
    guard attachments.count == note.files.count else { throw NotesError(description: "Imported file count differs for \(note.identifier)") }
    let actual = try attachments.map { item -> String in
        guard let path = item["path"] as? String else { throw NotesError(description: "Imported attachment has no local file") }
        return try fileDigest(path)
    }.sorted()
    let expected = try note.files.map { path -> String in
        guard let digest = digests[path], try fileDigest(path) == digest else { throw NotesError(description: "Bear file changed during import: \(path)") }
        return digest
    }.sorted()
    guard actual == expected else { throw NotesError(description: "Imported file SHA-256 differs for \(note.identifier)") }
    let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/,"))
    let expectedTags = Set(note.tags.flatMap { $0.components(separatedBy: separators) }.filter { !$0.isEmpty }.map { "#" + $0.lowercased() })
    let actualTags = Set((state["tags"] as? [[String: Any]] ?? []).compactMap { ($0["name"] as? String)?.lowercased() })
    guard actualTags == expectedTags else { throw NotesError(description: "Imported native tags differ for \(note.identifier): \(actualTags) instead of \(expectedTags)") }
    let text = state["text"] as? String ?? ""
    guard !text.contains("NBATTACHMENT") && !text.contains("NBTODO") else { throw NotesError(description: "Unresolved import marker in \(note.identifier)") }
    return actual.count
}

struct ImportBear: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(commandName: "import-bear", abstract: "Import this user's Bear notes, folders, native tags and attachments", discussion: """
        Imports notes, files and tags into folders matching Bear tag paths. Requires pandoc.
        Reruns skip existing imports. Bear data is never modified.
        Try --dry-run first. Progress uses stderr. Saved note UUIDs use stdout.
        Saves locally, run abdy notes sync after the last write to send changes to iCloud.

        EXAMPLES
          abdy notes import-bear --dry-run
          abdy notes import-bear
        """)
    @Option(help: "Bear Application Data directory, defaults to this user's local Bear store") var source: String?
    @Option(help: "pandoc executable") var pandoc = "/opt/homebrew/bin/pandoc"
    @Option(help: "Import only the first N active notes") var limit: Int?
    @Flag(help: "Validate and report inventory without changing Notes") var dryRun = false
    @Flag(help: "Restore existing imported notes to their Bear tag folder paths") var repairFolders = false

    func run() throws {
        if let limit, limit <= 0 { throw ValidationError("--limit must be positive") }
        let directory = source.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Group Containers/9K33E3U3T4.net.shinyfrog.bear/Application Data")
        let all = try readBearNotes(at: directory)
        let notes = Array(all.prefix(limit ?? all.count))
        let tagCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-/"))
        let rejectedTags = Set(notes.flatMap(\.tags)).filter { tag in
            tag.unicodeScalars.contains { !tagCharacters.contains($0) } || tag.split(separator: "/", omittingEmptySubsequences: false).contains("")
        }.sorted()
        guard rejectedTags.isEmpty else { throw NotesError(description: "Bear tags are not valid Notes tags: \(rejectedTags.joined(separator: ", "))") }
        let byTitle = Dictionary(grouping: all, by: \.title)
        for note in notes {
            for title in try bearReferences(note) {
                guard byTitle[title]?.count == 1 else { throw NotesError(description: "Unresolved or ambiguous Bear reference: \(title)") }
            }
        }
        let inventory: [String: Any] = ["sourceNotes": all.count, "selectedNotes": notes.count, "files": notes.reduce(0) { $0 + $1.files.count }, "destinations": Set(notes.map(\.destination)).sorted()]
        if dryRun { try output.write(inventory); return }
        guard FileManager.default.isExecutableFile(atPath: pandoc) else { throw NotesError(description: "pandoc executable not found: \(pandoc)") }
        let digests = try Dictionary(uniqueKeysWithValues: Set(notes.flatMap(\.files)).map { ($0, try fileDigest($0)) })
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let store = try openLocalNotes(readOnly: false)
        var folders = try store.listFolders()
        var destinations: [String: String] = [:]
        func destination(_ path: String) throws -> String {
            if let id = destinations[path] { return id }
            var parent: String?
            for part in path.split(separator: "/").map(String.init) {
                let matches = folders.filter { ($0["name"] as? String) == part && ($0["parent"] as? String) == parent }
                guard matches.count <= 1 else { throw NotesError(description: "Ambiguous destination folder: \(path)") }
                if let id = matches.first?["id"] as? String { parent = id }
                else {
                    let id = try store.createFolder(part, parent: parent)
                    var entry: [String: Any] = ["id": id, "name": part]
                    if let parent { entry["parent"] = parent }
                    folders.append(entry)
                    parent = id
                }
            }
            guard let parent else { throw NotesError(description: "Empty Bear folder path") }
            destinations[path] = parent
            return parent
        }
        var records: [[String: Any]] = []
        var imported = 0
        var skipped = 0
        var moved = 0
        var identifiers: [String: String] = [:]
        for path in Set(notes.flatMap(\.tags) + notes.map(\.destination)).sorted() { _ = try destination(path) }
        let existingImports = try store.finishedImports(notes.map(\.notesIdentifier))
        for note in notes {
            try autoreleasepool {
                let result: [AnyHashable: Any]
                if let id = existingImports[note.notesIdentifier] {
                    let state = try store.readNote(id)
                    if state["folderPath"] as? String != note.destination {
                        guard repairFolders else { throw NotesError(description: "Existing import is in the wrong folder: \(note.identifier), use --repair-folders") }
                        _ = try store.moveNotes(withIDs: [id], toFolder: destination(note.destination))
                        moved += 1
                    }
                    result = ["id": id, "imported": false]
                }
                else {
                    let html = try renderBearHTML(bearMarkdown(note), pandoc: pandoc, directory: scratch)
                    result = try store.importNote(withIdentifier: note.notesIdentifier, folder: destination(note.destination), html: html, tags: note.tags.joined(separator: ","), files: note.files)
                }
                identifiers[note.identifier] = result["id"] as? String
                if result["imported"] as? Bool == true { imported += 1 } else { skipped += 1 }
                let record: [String: Any] = ["bear": note.identifier, "id": result["id"]!, "imported": result["imported"]!]
                records.append(record)
                FileHandle.standardError.write(Data("Bear \(note.identifier) -> \(note.notesIdentifier)\n".utf8))
            }
        }
        var linked = 0
        var deferredLinks = 0
        for note in notes {
            guard let sourceID = identifiers[note.identifier] else { continue }
            for title in try bearReferences(note) {
                guard let target = byTitle[title]?.first, let targetID = identifiers[target.identifier] else { deferredLinks += 1; continue }
                let text = try store.readNote(sourceID)["text"] as? String ?? ""
                let find = "[[\(title)]]"
                if text.contains(find) {
                    _ = try store.editNote(sourceID, operation: "link-replace", options: ["find": find, "target": targetID])
                    linked += 1
                }
            }
        }
        try store.queueUnsyncedObjects(Array(identifiers.values) + Array(destinations.values))
        let reopened = try openLocalNotes(readOnly: true)
        var verifiedFiles = 0
        var verifiedIDs: [String] = []
        for (index, note) in notes.enumerated() {
            guard let id = identifiers[note.identifier] else { throw NotesError(description: "Missing imported note id") }
            let state = try reopened.readNote(id)
            verifiedFiles += try verifyBearNote(note, state: state, digests: digests)
            guard var record = state as? [String: Any] else { throw NotesError(description: "Invalid imported note data") }
            record["bear"] = note.identifier
            record["imported"] = records[index]["imported"]!
            record["files"] = note.files.count
            records[index] = output.actionResult("import-bear", data: record)
            verifiedIDs.append(id)
        }
        FileHandle.standardError.write(Data("Imported: \(imported), skipped: \(skipped), moved: \(moved), linked: \(linked)\n".utf8))
        try output.write(["notes": records, "summary": ["imported": imported, "skipped": skipped, "moved": moved, "total": notes.count, "files": inventory["files"]!, "verifiedFiles": verifiedFiles, "verifiedNotes": identifiers.count, "linked": linked, "deferredLinks": deferredLinks]], text: verifiedIDs.joined(separator: "\n"))
    }
}
