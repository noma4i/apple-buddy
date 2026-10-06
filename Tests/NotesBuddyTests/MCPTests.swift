import Darwin
import Foundation
import XCTest
import MCP
@testable import notes_buddy

final class MCPTestSession {
    let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var nextID = 0

    init(home: URL? = nil, throughPATH: Bool = false) throws {
        let binary = URL(fileURLWithPath: ".build/debug/nb")
        process.executableURL = throughPATH ? URL(fileURLWithPath: "/bin/zsh") : binary
        process.arguments = throughPATH ? ["-f", "-c", "nb mcp"] : ["mcp"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        if let home { environment["CFFIXED_USER_HOME"] = home.path }
        if throughPATH { environment["PATH"] = binary.deletingLastPathComponent().path + ":" + (environment["PATH"] ?? "") }
        process.environment = environment
        try process.run()
    }

    deinit {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    func request(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        nextID += 1
        let request: [String: Any] = ["jsonrpc": "2.0", "id": nextID, "method": method, "params": params]
        try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let newline = buffer.firstIndex(of: 10) {
                let data = buffer[..<newline]
                buffer.removeSubrange(...newline)
                let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                if response["id"] as? Int == nextID { return response }
                continue
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) > 0 {
                let data = output.fileHandleForReading.availableData
                guard !data.isEmpty else { throw NotesError(description: "MCP closed stdout before replying") }
                buffer.append(data)
            }
        }
        throw NotesError(description: "MCP did not reply before the test deadline")
    }

    func initialize() throws -> [String: Any] {
        let response = try request("initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "nb-tests", "version": "1"]])
        try input.fileHandleForWriting.write(contentsOf: Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n".utf8))
        return response
    }

    func finish() throws {
        try input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertFalse(process.isRunning, "MCP must exit on stdin EOF")
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

final class MCPTests: XCTestCase {
    func testMCPInvokesItsOwnBinaryWhenStartedThroughPATH() throws {
        let session = try MCPTestSession(throughPATH: true)
        _ = try session.initialize()
        let response = try session.request("tools/call", ["name": "help", "arguments": ["command": "search"]])
        XCTAssertEqual((response["result"] as? [String: Any])?["isError"] as? Bool, false)
        try session.finish()
    }

    func testMCPToolSchemasRequireOnlyArgumentsUsedByTheirAction() throws {
        let definitions = try MCPToolCommand.all()
        let add = try XCTUnwrap(definitions.first { $0.tool.name == "attachments_add" })
        let required = add.tool.inputSchema.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue)
        XCTAssertTrue(required?.contains("file") == true)
        XCTAssertThrowsError(try add.invocation(["id": "4B34F396"], definitions: definitions))
        XCTAssertNil(add.types["attachment"])
        let move = try XCTUnwrap(definitions.first { $0.tool.name == "attachments_mv" })
        XCTAssertTrue(move.tool.inputSchema.objectValue?["required"]?.arrayValue?.contains("to") == true)
        let list = try XCTUnwrap(definitions.first { $0.tool.name == "attachments_ls" })
        XCTAssertEqual(Set(list.types.keys), ["id"])
        let link = try XCTUnwrap(definitions.first { $0.tool.name == "links_add" })
        XCTAssertThrowsError(try link.invocation(["id": "4B34F396"], definitions: definitions))
        let export = try XCTUnwrap(definitions.first { $0.tool.name == "attachments_export" })
        XCTAssertNotNil(export.tool.inputSchema.objectValue?["oneOf"])
        XCTAssertThrowsError(try export.invocation(["id": "4B34F396"], definitions: definitions))
        let search = try XCTUnwrap(definitions.first { $0.tool.name == "search" })
        let invocation = try search.invocation(["query": "help", "limit": 2], definitions: definitions)
        XCTAssertTrue(try NotesBuddy.parseAsRoot(invocation.arguments) is Search)
        XCTAssertThrowsError(try search.invocation(["query": "help", "limit": "2"], definitions: definitions))
        XCTAssertEqual(search.types["chars"], "integer")
        XCTAssertEqual(search.types["show"], "boolean")
        let notes = try XCTUnwrap(definitions.first { $0.tool.name == "ls" })
        XCTAssertEqual(notes.types["limit"], "integer")
        XCTAssertEqual(notes.types["offset"], "integer")
        XCTAssertEqual(notes.types["chars"], "integer")
        XCTAssertEqual(notes.types["show"], "boolean")
        XCTAssertTrue(try NotesBuddy.parseAsRoot(try notes.invocation(["folder": "Work", "show": true, "chars": 100, "limit": 3], definitions: definitions).arguments) is List)
        let moveNotes = try XCTUnwrap(definitions.first { $0.tool.name == "mv" })
        XCTAssertEqual(moveNotes.types["ids"], "array")
        XCTAssertNil(moveNotes.types["stdin"])
        let batch = try moveNotes.invocation(["ids": ["4B34F396", "5C45A4A7"], "folder": "Work"], definitions: definitions)
        XCTAssertEqual(batch.arguments, ["mv", "--json", "--folder=Work", "--", "4B34F396", "5C45A4A7"])
        XCTAssertThrowsError(try moveNotes.invocation(["ids": "4B34F396", "folder": "Work"], definitions: definitions))
        let tags = try XCTUnwrap(definitions.first { $0.tool.name == "tags" })
        XCTAssertEqual(tags.types["ids"], "array")
        XCTAssertTrue(try NotesBuddy.parseAsRoot(try tags.invocation(["rename": "a", "to": "b"], definitions: definitions).arguments) is Tags)
        for name in ["mvfolder", "renamefolder", "dups"] { XCTAssertNotNil(definitions.first { $0.tool.name == name }, name) }
    }

    func testOpenCommandAcceptsUUIDPrefixesAndHasHelp() throws {
        XCTAssertNoThrow(try NotesBuddy.parseAsRoot(["open", "4B34F396"]))
        XCTAssertTrue(NotesBuddy._dumpHelp().contains("\"commandName\" : \"open\""))
    }

    func testMCPNegotiatesListsDescribedToolsReturnsErrorsAndExitsOnEOF() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = try MCPTestSession(home: home)
        let initialized = try session.initialize()
        let initialization = try XCTUnwrap(initialized["result"] as? [String: Any])
        XCTAssertEqual((initialization["serverInfo"] as? [String: Any])?["name"] as? String, "notes-buddy")
        let response = try session.request("tools/list")
        let tools = try XCTUnwrap((response["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(Set(["search", "show", "open", "new", "mv", "pin", "unpin", "backup", "restore", "stats", "table_set", "attachments_export", "links_add", "help"]).isSubset(of: names))
        XCTAssertFalse(names.contains("mcp"))
        for tool in tools {
            XCTAssertFalse((tool["description"] as? String ?? "").isEmpty)
            XCTAssertEqual((tool["inputSchema"] as? [String: Any])?["type"] as? String, "object")
        }
        let help = try session.request("tools/call", ["name": "help", "arguments": ["command": "attachments_export"]])
        XCTAssertEqual((help["result"] as? [String: Any])?["isError"] as? Bool, false)
        XCTAssertTrue(String(describing: help).contains("nb attachments"))
        let invalid = try session.request("tools/call", ["name": "show", "arguments": ["id": "missing-id", "unexpected": true]])
        XCTAssertEqual((invalid["result"] as? [String: Any])?["isError"] as? Bool, true)
        let unknown = try session.request("tools/call", ["name": "arbitrary-shell", "arguments": [:]])
        XCTAssertEqual((unknown["result"] as? [String: Any])?["isError"] as? Bool, true)
        try session.finish()
    }
}
