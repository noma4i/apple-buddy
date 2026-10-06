import Foundation

func nbBinaryURL() -> URL {
    let alias = URL(fileURLWithPath: ".build/debug/nb")
    if !FileManager.default.fileExists(atPath: alias.path) { try? FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: "abdy") }
    return alias
}
