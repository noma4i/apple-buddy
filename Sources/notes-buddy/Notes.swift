import ArgumentParser
import Foundation

enum ReferenceHelp {
    static let note: ArgumentHelp = "Note UUID, unique prefix or applenotes URL from ls, search or new"
    static let folder = "name, path such as Work/Project, UUID or unique prefix"
    static let attachment: ArgumentHelp = "Attachment file name, UUID or unique prefix from attachments ls"
    static let tag = "name with or without #"
}

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
    let url: String
    let title: String
    let folder: String
    let folderPath: String
    let modified: Date
    let attachments: [NoteAttachment]
    let urls: [NoteWebURL]?
}

struct NoteWebURL: Codable {
    let name: String
    let url: String
    let location: Int
    let length: Int
}

struct NoteAttachment: Codable {
    let id: String
    let identifier: String
    let note: String
    let type: String
    let name: String
    let available: Bool
    let exportable: Bool
    let viewSize: Int
    let path: String?
    let url: String?
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
        guard let id = value["id"] as? String, let url = value["url"] as? String, let title = value["title"] as? String, let modified = value["modified"] as? Date,
              let folderID = value["folder"] as? String, let folderPath = value["folderPath"] as? String else { throw NotesError(description: "Notes returned invalid note data") }
        guard let items = value["attachments"] as? [[String: Any]] else { throw NotesError(description: "Notes returned invalid attachment data") }
        let attachments = try JSONDecoder().decode([NoteAttachment].self, from: JSONSerialization.data(withJSONObject: items))
        guard let links = value["urls"] else { throw NotesError(description: "Notes returned invalid web link data") }
        let urls = try JSONDecoder().decode([NoteWebURL]?.self, from: JSONSerialization.data(withJSONObject: links, options: [.fragmentsAllowed]))
        return Note(id: id, url: url, title: title, folder: folderID, folderPath: folderPath, modified: modified, attachments: attachments, urls: urls)
    }
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
