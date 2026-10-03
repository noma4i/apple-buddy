import Foundation

struct NotesError: Error, CustomStringConvertible {
    let description: String
}

struct Folder: Codable {
    let id: String
    let name: String
    let parent: String?
}

struct Note: Codable {
    let id: String
    let title: String
    let folder: String
    let modified: Date
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func listFolders() throws -> [Folder] {
    try openLocalNotes(readOnly: true).listFolders().map { value in
        guard let id = value["id"] as? String, let name = value["name"] as? String else { throw NotesError(description: "Notes returned invalid folder data") }
        return Folder(id: id, name: name, parent: value["parent"] as? String)
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
