import Foundation

struct NotesError: Error, CustomStringConvertible {
    let description: String
}

struct Folder: Codable {
    let id: String
    let name: String
    let parent: String?
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

struct Note: Codable {
    let id: String
    let title: String
    let folder: String
    let modified: Date
}

func listFolders() throws -> [Folder] {
    try openLocalNotes(readOnly: true).listFolders().map { value in
        guard let id = value["id"] as? String, let name = value["name"] as? String else { throw NotesError(description: "Notes returned invalid folder data") }
        guard let path = value["path"] as? String, let noteCount = value["noteCount"] as? Int,
              let deletedCount = value["deletedNoteCount"] as? Int, let childCount = value["subfolderCount"] as? Int,
              let empty = value["empty"] as? Bool else { throw NotesError(description: "Notes returned invalid folder statistics") }
        return Folder(id: id, name: name, parent: value["parent"] as? String, path: path, noteCount: noteCount, deletedNoteCount: deletedCount, subfolderCount: childCount, empty: empty)
    }
}

func listNotes(in folder: Folder) throws -> [Note] {
    try openLocalNotes(readOnly: true).listNotes(inFolder: folder.id).map { value in
        guard let id = value["id"] as? String, let title = value["title"] as? String, let modified = value["modified"] as? Date else { throw NotesError(description: "Notes returned invalid note data") }
        return Note(id: id, title: title, folder: folder.name, modified: modified)
    }
}

func resolveFolder(named name: String) throws -> Folder {
    let matches = try listFolders().filter { $0.name == name || $0.id == name }
    guard let folder = matches.first else { throw NotesError(description: "folder not found: \(name)") }
    guard matches.count == 1 else { throw NotesError(description: "folder name is ambiguous: \(name)") }
    return folder
}

func noteBody(id: String) throws -> String {
    try openLocalNotes(readOnly: true).html(forNote: id)
}

func setNoteBody(id: String, html: String) throws {
    try openLocalNotes(readOnly: false).setHTML(html, forNote: id)
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
