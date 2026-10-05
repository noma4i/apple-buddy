import ArgumentParser
import CoreFoundation
import Foundation

struct OutputOptions: ParsableArguments {
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

    func writeAction(_ action: String, _ value: Any, text: String) throws {
        guard let data = value as? [String: Any] else { throw NotesError(description: "Notes returned invalid action data") }
        let result = actionResult(action, data: data)
        try write(result, text: text)
        summary(actionSummary(result))
    }

    func summary(_ text: String) {
        if !json { FileHandle.standardError.write(Data((text + "\n").utf8)) }
    }

    func write(_ value: Any, text: String? = nil) throws {
        let result = try format(value, text: text)
        if !result.isEmpty { print(result) }
    }

    func format(_ value: Any, text: String? = nil) throws -> String {
        if json {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
            return String(decoding: data, as: UTF8.self)
        }
        return text ?? render(value)
    }

    func writeEncodable<T: Encodable>(_ value: T, text: String) throws {
        guard json else { try write(text, text: text); return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: encoder.encode(value), options: .fragmentsAllowed)
        try write(object)
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
