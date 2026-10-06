import ArgumentParser
import Foundation

enum ReferenceHelp {
    static let noteText = "Note UUID, unique prefix or applenotes URL from ls, search or new"
    static let attachmentText = "Attachment file name, UUID or unique prefix from attachments ls"
    static let note = ArgumentHelp(noteText)
    static let folder = "name, path such as Work/Project, UUID or unique prefix"
    static let attachment = ArgumentHelp(attachmentText)
    static let tag = "name with or without #"
}

struct NotesError: Error, CustomStringConvertible {
    let description: String
}

struct Folder: Codable {
    let id: String
    let name: String
    let parent: String?
    let parentPath: String?
    let totalNoteCount: Int
    let totalDeletedNoteCount: Int
    let path: String
    let noteCount: Int
    let deletedNoteCount: Int
    let subfolderCount: Int
    let empty: Bool

    var summary: String {
        "\(path)\n  \(noteCount) notes, \(deletedNoteCount) deleted notes, \(subfolderCount) subfolders, empty=\(empty)\n  \(id)"
    }
}

func noteActionData(id: String, fields: [String: Any] = [:]) throws -> [String: Any] {
    guard var result = try openLocalNotes(readOnly: true).readNote(id) as? [String: Any] else { throw NotesError(description: "Notes returned invalid note data") }
    for (key, value) in fields { result[key] = value }
    return result
}

func noteReferences(_ ids: [String]) throws -> [String] {
    guard ids == ["-"] else { return ids }
    var lines: [String] = []
    while let line = readLine() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { lines.append(trimmed) }
    }
    guard !lines.isEmpty else { throw ValidationError("stdin has no ids, 1 per line") }
    return lines
}

func listFolders() throws -> [Folder] {
    try openLocalNotes(readOnly: true).listFolders().map { value in
        guard let id = value["id"] as? String, let name = value["name"] as? String else { throw NotesError(description: "Notes returned invalid folder data") }
        guard let path = value["path"] as? String, let noteCount = value["noteCount"] as? Int,
              let deletedCount = value["deletedNoteCount"] as? Int, let childCount = value["subfolderCount"] as? Int,
              let empty = value["empty"] as? Bool, let total = value["totalNoteCount"] as? Int,
              let totalDeleted = value["totalDeletedNoteCount"] as? Int else { throw NotesError(description: "Notes returned invalid folder statistics") }
        return Folder(id: id, name: name, parent: value["parent"] as? String, parentPath: value["parentPath"] as? String, totalNoteCount: total, totalDeletedNoteCount: totalDeleted, path: path, noteCount: noteCount, deletedNoteCount: deletedCount, subfolderCount: childCount, empty: empty)
    }
}

func foldersWithDescendants(of root: Folder, in all: [Folder]) -> [Folder] {
    var included: Set<String> = [root.id]
    var changed = true
    while changed {
        let previous = included.count
        for candidate in all where candidate.parent.map(included.contains) == true { included.insert(candidate.id) }
        changed = included.count != previous
    }
    return all.filter { included.contains($0.id) }
}

func resolveFolder(named name: String) throws -> Folder {
    let id = try openLocalNotes(readOnly: true).canonicalID(forReference: name, entity: "ICFolder")
    guard let folder = try listFolders().first(where: { $0.id == id }) else { throw NotesError(description: "Notes returned no data for folder \(name)") }
    return folder
}

func noteBody(id: String) throws -> String {
    try openLocalNotes(readOnly: true).html(forNote: id)
}

func setNoteBody(id: String, html: String) throws {
    try openLocalNotes(readOnly: false).setHTML(html, forNote: id)
}

func readableFilePath(_ file: String) throws -> String {
    let path = URL(fileURLWithPath: file).standardizedFileURL.path
    guard FileManager.default.isReadableFile(atPath: path) else { throw NotesError(description: "file not readable: \(path)") }
    return path
}

func readHTML(from path: String?) throws -> String {
    guard let path else { return "" }
    let data = path == "-" ? FileHandle.standardInput.readDataToEndOfFile() : try Data(contentsOf: URL(fileURLWithPath: path))
    return String(decoding: data, as: UTF8.self)
}

func escapeHTML(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
