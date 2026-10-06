import ArgumentParser
import CoreFoundation
import Foundation
import NotesNative

struct OutputOptions: ParsableArguments {
    private static let idFields: Set<String> = ["id", "note", "folder", "parent", "target", "attachment", "link", "source", "destination"]
    @Flag(help: "Print data as JSON instead of text") var json = false

    func actionResult(_ action: String, data: [String: Any]) -> [String: Any] {
        var result = data
        result["action"] = action
        result["saved"] = true
        for key in ["needsCloudPush", "cloudAcknowledged", "inCloud"] { result.removeValue(forKey: key) }
        return result
    }

    func actionSummary(_ data: [String: Any]) -> String {
        let object: Any
        if let title = data["title"] as? String, let folder = data["folderPath"] as? String {
            object = "\(title) in \(folder)"
        } else {
            object = data["path"] ?? data["folderPath"] ?? data["id"] ?? ""
        }
        var details = ["\(data["action"] ?? ""): \(object)"]
        if let count = data["noteCount"] as? Int { details.append("\(count) notes") }
        if let count = data["subfolderCount"] as? Int { details.append("\(count) subfolders") }
        for key in ["empty", "pinned", "deleted", "moved"] {
            if let value = data[key] as? Bool { details.append("\(key)=\(value)") }
        }
        return details.joined(separator: ", ")
    }

    func writeAction(_ action: String, _ value: Any) throws {
        guard let data = value as? [String: Any] else { throw NotesError(description: "Notes returned invalid action data") }
        let result = actionResult(action, data: data)
        guard let id = result["id"] as? String else { throw NotesError(description: "Notes returned no action UUID") }
        try write(result, text: id)
        summary(actionSummary(result))
        if !json, let pending = try openLocalNotes(readOnly: true).cloudStatus()["pendingObjects"] as? Int, pending > 0 {
            summary("Saved locally, run nb sync to send it to iCloud")
        }
    }

    func summary(_ text: String) {
        if !json { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    }

    func write(_ value: Any, text: String? = nil) throws {
        let references = coreDataIDs(in: value)
        let ids = references.isEmpty ? [:] : try openLocalNotes(readOnly: true).publicIdentifiers(forIDs: Array(references))
        let data = replaceIDs(in: value, using: ids)
        let plain = text.map { content in
            content.components(separatedBy: "\n").map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let uuid = ids[trimmed] { return line.replacingOccurrences(of: trimmed, with: uuid) }
                if trimmed.hasPrefix("Export: nb ") {
                    return ids.reduce(line) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
                }
                return line
            }.joined(separator: "\n")
        }
        let result = try format(data, text: plain)
        if !result.isEmpty { print(result) }
    }

    func format(_ value: Any, text: String? = nil) throws -> String {
        if json {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
        }
        return text ?? render(value)
    }

    func writeEncodable<T: Encodable>(_ value: T, text: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: encoder.encode(value), options: .fragmentsAllowed)
        try write(object, text: text)
    }

    private func coreDataIDs(in value: Any, key: String? = nil) -> Set<String> {
        if let fields = value as? [String: Any] {
            return fields.reduce(into: Set<String>()) { $0.formUnion(coreDataIDs(in: $1.value, key: $1.key)) }
        }
        if let items = value as? [Any] { return items.reduce(into: Set<String>()) { $0.formUnion(coreDataIDs(in: $1, key: key)) } }
        if let id = value as? String, id.hasPrefix("x-coredata://"), Self.idFields.contains(key ?? "id") { return [id] }
        return []
    }

    private func replaceIDs(in value: Any, using ids: [String: String], key: String? = nil) -> Any {
        if let fields = value as? [String: Any] { return fields.reduce(into: [String: Any]()) { $0[$1.key] = replaceIDs(in: $1.value, using: ids, key: $1.key) } }
        if let items = value as? [Any] { return items.map { replaceIDs(in: $0, using: ids, key: key) } }
        if let id = value as? String, Self.idFields.contains(key ?? "id"), let uuid = ids[id] { return uuid }
        return value
    }


    private func render(_ value: Any, indent: String = "") -> String {
        if let fields = value as? [String: Any] {
            return fields.keys.sorted().map { key in
                let value = fields[key]!
                if value is [String: Any] || value is [Any] {
                    return "\(indent)\(key):\n" + render(value, indent: indent + "  ")
                }
                return "\(indent)\(key): " + render(value)
            }.joined(separator: "\n")
        }
        if let items = value as? [Any] {
            guard !items.isEmpty else { return indent + "none" }
            return items.map { value in
                if value is [String: Any] || value is [Any] {
                    return indent + "-\n" + render(value, indent: indent + "  ")
                }
                return indent + "- " + render(value)
            }.joined(separator: "\n")
        }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return indent + (number.boolValue ? "true" : "false")
        }
        return indent + String(describing: value)
    }
}
