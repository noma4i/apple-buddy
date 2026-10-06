import ArgumentParser
import ArgumentParserToolInfo
import Darwin
import Foundation
import MCP

struct MCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Serve CLI tools to agents over MCP stdio",
        discussion: "Connect an MCP client with command abdy and arguments [mcp]. The nb alias with [mcp] starts the same server. Uses this Mac's Notes account. Tools have typed parameters and descriptions. Writes save locally, call sync once after the last write. Stdin and stdout carry MCP messages only. The server exits when the client disconnects."
    )

    func run() throws {
        signal(SIGPIPE, SIG_IGN)
        let definitions = try MCPToolCommand.all()
        guard let executable = Bundle.main.executableURL else { throw ValidationError("Cannot locate the abdy executable") }
        let commands = MCPCommands(executable: executable.resolvingSymlinksInPath())
        let server = Server(name: "apple-buddy", version: AppleBuddy.releaseVersion,
                            instructions: "Tools are grouped: notes_*, reminders_* and calendar_*. Reminders and Calendar need access once, run reminders_access or calendar_access when a tool reports missing access. Use notes_search or notes_ls to get note UUIDs. Unique prefixes need at least 8 characters. Folders accept a name, a path such as Work/Project or a UUID from folders. A folder filter in ls, search and stats includes subfolders. ls and search with show return note text in one call, chars caps each text and limit caps the count. Tools return CLI JSON data. Writes save locally and return at once. Call sync once after the last write to send changes to iCloud, pin and unpin sync on their own. Only open displays Notes. Export saves local files. Restore creates an isolated copy, never overwrites live Notes. Use help for command details.",
                            capabilities: .init(tools: .init()))
        let completed = DispatchSemaphore(value: 0)
        let outcome = MCPCompletion()
        let signals = [SIGINT, SIGTERM, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                commands.stop()
                Task { await server.stop() }
            }
            source.resume()
            return source
        }
        Task {
            do {
                await server.withMethodHandler(ListTools.self) { _ in .init(tools: definitions.map(\.tool)) }
                await server.withMethodHandler(CallTool.self) { params in
                    do {
                        guard let definition = definitions.first(where: { $0.tool.name == params.name }) ?? definitions.first(where: { $0.tool.name == "notes_" + params.name }) else {
                            throw ValidationError("Unknown tool: \(params.name)")
                        }
                        let invocation = try definition.invocation(params.arguments ?? [:], definitions: definitions)
                        let process = Process()
                        return try await withTaskCancellationHandler {
                            try commands.execute(invocation.arguments, input: invocation.input, text: params.name == "help", process: process)
                        } onCancel: {
                            if process.isRunning { process.terminate() }
                        }
                    } catch {
                        return .init(content: [.text(text: String(describing: error), annotations: nil, _meta: nil)], isError: true)
                    }
                }
                try await server.start(transport: StdioTransport())
                await server.waitUntilCompleted()
            } catch { outcome.error = error }
            commands.stop()
            commands.waitUntilIdle()
            completed.signal()
        }
        completed.wait()
        for source in signals { source.cancel() }
        if let error = outcome.error { throw error }
    }
}

private final class MCPCompletion: @unchecked Sendable {
    var error: Swift.Error?
}

struct MCPToolCommand {
    let tool: Tool
    let command: [String]
    let arguments: [ArgumentInfoV0]
    let types: [String: String]

    private static func requiredOptions(for command: [String]) -> Set<String> {
        if command.dropLast().last == "attachments", let action = command.last.flatMap(Attachments.Action.init(rawValue:)) { return Attachments.requiredOptionsForActions[action] ?? [] }
        if command.dropLast().last == "links", let action = command.last.flatMap(Links.Action.init(rawValue:)) { return Links.requiredOptionsForActions[action] ?? [] }
        return []
    }

    static func all() throws -> [MCPToolCommand] {
        let info = try JSONDecoder().decode(ToolInfoV0.self, from: Data(AppleBuddy._dumpHelp().utf8))
        func visit(_ info: CommandInfoV0, prefix: [String]) -> [MCPToolCommand] {
            let command = prefix + [info.commandName]
            if ["mcp", "help"].contains(info.commandName) { return [] }
            if let children = info.subcommands, !children.isEmpty { return children.flatMap { visit($0, prefix: command) } }
            if info.commandName == "attachments" { return Attachments.Action.allCases.map { make(info, command: command + [$0.rawValue]) } }
            if info.commandName == "links" { return Links.Action.allCases.map { make(info, command: command + [$0.rawValue]) } }
            return [make(info, command: command)]
        }
        var commands = (info.command.subcommands ?? []).flatMap { visit($0, prefix: []) }
        let help = Tool(name: "help", description: "Read command help without opening Notes. Pass a tool name, or omit command for CLI help.",
                        inputSchema: .object(["type": "object", "properties": .object(["command": .object(["type": "string", "description": "Tool name, for example notes_search or notes_attachments_export"])]), "additionalProperties": false]),
                        annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false))
        commands.append(.init(tool: help, command: [], arguments: [], types: ["command": "string"]))
        return commands
    }

    private static func make(_ info: CommandInfoV0, command: [String]) -> MCPToolCommand {
        let arguments = (info.arguments ?? []).filter { argument in
            guard argument.shouldDisplay, let name = argument.valueName, !["json", "help", "version", "action"].contains(name) else { return false }
            if command.dropLast().last == "attachments", let action = command.last.flatMap(Attachments.Action.init(rawValue:)), let actions = Attachments.optionsForActions[name] { return actions.contains(action) }
            if command.dropLast().last == "links", let action = command.last.flatMap(Links.Action.init(rawValue:)), let actions = Links.optionsForActions[name] { return actions.contains(action) }
            return true
        }
        var properties: [String: Value] = [:]
        var types: [String: String] = [:]
        var required: [Value] = []
        for argument in arguments {
            guard let name = argument.valueName else { continue }
            let type = argument.kind == .flag ? "boolean" : argument.isRepeating ? "array" : (["row", "col", "table", "at", "limit", "offset", "chars"].contains(name) || (command.dropLast().last == "attachments" && name == "size")) ? "integer" : "string"
            types[name] = type
            var property: [String: Value] = ["type": .string(type), "description": .string(argument.abstract ?? name)]
            if type == "array" { property["items"] = .object(["type": .string(name == "alarm" ? "integer" : "string")]) }
            if let values = argument.allValueStrings, !values.isEmpty { property["enum"] = .array(values.map(Value.string)) }
            if name == "size" && command.dropLast().last == "attachments" { property["enum"] = [0, 1, 2] }
            properties[name] = .object(property)
            if !argument.isOptional || requiredOptions(for: command).contains(name) { required.append(.string(name)) }
        }
        if arguments.contains(where: { ["html", "csv"].contains($0.valueName ?? "") && $0.abstract?.contains("stdin") == true }) {
            properties["stdin"] = .object(["type": "string", "description": "Content for stdin. Set html or csv to - to use it."])
            types["stdin"] = "string"
        }
        let name = command.joined(separator: "_").replacingOccurrences(of: "-", with: "_")
        let readOnly = ["version", "notes_folders", "notes_ls", "notes_stats", "notes_show", "notes_search", "notes_inspect", "notes_dups", "notes_table_ls", "notes_attachments_ls", "notes_links_ls", "reminders_lists", "reminders_ls", "reminders_show", "reminders_search", "calendar_calendars", "calendar_events", "calendar_show"].contains(name)
        let additive = ["notes_new", "notes_mkfolder", "notes_insert", "notes_attach", "notes_attachments_add", "notes_links_add", "notes_pin", "notes_unpin", "notes_open", "notes_backup", "notes_restore", "notes_snapshot_db", "notes_attachments_export", "reminders_access", "reminders_mklist", "reminders_add", "calendar_access", "calendar_mkcal", "calendar_add"].contains(name)
        let action = ["attachments", "links"].contains(command.dropLast().last ?? "") ? command.last : nil
        let discussion = info.discussion.map { text in
            text.components(separatedBy: "\n").filter { line in
                guard let action, line.hasPrefix("  abdy ") else { return true }
                return line.hasPrefix("  abdy \(command.dropLast().joined(separator: " ")) \(action) ")
            }.joined(separator: "\n")
        }
        let description = [info.abstract, discussion].compactMap { $0 }.joined(separator: "\n\n") + "\nCLI: abdy " + command.joined(separator: " ") + ". Returns structured JSON. Every id, url, path and name in a result is accepted as input."
        var schema: [String: Value] = ["type": "object", "properties": .object(properties), "required": .array(required), "additionalProperties": false]
        if name == "notes_attachments_export" {
            schema["oneOf"] = .array([.object(["required": ["directory"], "not": .object(["required": ["file"]])]),
                                       .object(["required": ["attachment", "file"], "not": .object(["required": ["directory"]])])])
        }
        let tool = Tool(name: name, title: "abdy " + command.joined(separator: " "), description: description,
                        inputSchema: .object(schema),
                        annotations: .init(readOnlyHint: readOnly, destructiveHint: !readOnly && !additive, idempotentHint: readOnly || ["notes_pin", "notes_unpin"].contains(name), openWorldHint: true))
        return .init(tool: tool, command: command, arguments: arguments, types: types)
    }

    func invocation(_ values: [String: Value], definitions: [MCPToolCommand]) throws -> (arguments: [String], input: Data?) {
        for (name, value) in values {
            guard let type = types[name] else { throw ValidationError("Unknown parameter: \(name)") }
            let matches = type == "boolean" ? value.boolValue != nil : type == "integer" ? value.intValue != nil : type == "array" ? value.arrayValue?.allSatisfy { $0.stringValue != nil || $0.intValue != nil } == true : value.stringValue != nil
            guard matches else { throw ValidationError("\(name) must be a \(type)") }
        }
        if tool.name == "help" {
            let name = values["command"]?.stringValue ?? ""
            if name.isEmpty { return (["help"], nil) }
            guard let selected = definitions.first(where: { $0.tool.name == name && name != "help" }) ?? definitions.first(where: { $0.tool.name == "notes_" + name }) else { throw ValidationError("Unknown command: \(name)") }
            return (selected.command + ["help"], nil)
        }
        var options = command + ["--json"]
        var positionals: [String] = []
        for argument in arguments {
            guard let name = argument.valueName else { continue }
            guard let value = values[name] else {
                if !argument.isOptional || Self.requiredOptions(for: command).contains(name) { throw ValidationError("Missing parameter: \(name)") }
                continue
            }
            let text = value.stringValue ?? value.intValue.map(String.init) ?? ""
            let values = value.arrayValue?.compactMap { $0.stringValue ?? $0.intValue.map(String.init) } ?? []
            if argument.isRepeating && argument.kind == .positional { positionals += values }
            else if argument.isRepeating, let option = argument.preferredName?.name { options += values.map { "--" + option + "=" + $0 } }
            else if argument.kind == .positional { positionals.append(text) }
            else if let option = argument.preferredName?.name {
                if argument.kind == .flag { if value.boolValue == true { options.append("--" + option) } }
                else { options.append("--" + option + "=" + text) }
            }
        }
        if !positionals.isEmpty { options += ["--"] + positionals }
        let input = values["stdin"]?.stringValue.map { Data($0.utf8) }
        if input != nil && !["html", "csv"].contains(where: { values[$0]?.stringValue == "-" }) { throw ValidationError("stdin requires html or csv set to -") }
        if input == nil && ["html", "csv"].contains(where: { values[$0]?.stringValue == "-" }) { throw ValidationError("Provide stdin content when html or csv is -") }
        let parsed = try AppleBuddy.parseAsRoot(options)
        if let export = parsed as? Attachments, export.action == .export { try export.validateExportDestination() }
        return (options, input)
    }
}

private final class MCPCommands: @unchecked Sendable {
    private let executable: URL
    private let execution = NSLock()
    private let state = NSLock()
    private var active: Process?
    private var stopped = false

    init(executable: URL) { self.executable = executable }

    func stop() {
        state.lock()
        stopped = true
        if let active, active.isRunning { active.terminate() }
        state.unlock()
    }

    func waitUntilIdle() {
        execution.lock()
        execution.unlock()
    }

    func execute(_ arguments: [String], input: Data?, text: Bool, process: Process) throws -> CallTool.Result {
        execution.lock()
        defer { execution.unlock() }
        try Task.checkCancellation()
        let output = Pipe(), errors = Pipe(), stdin = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = stdin
        state.lock()
        guard !stopped else { state.unlock(); throw ValidationError("MCP is stopping") }
        active = process
        do { try process.run() } catch { active = nil; state.unlock(); throw error }
        if Task.isCancelled { process.terminate() }
        state.unlock()
        defer {
            state.lock()
            active = nil
            state.unlock()
        }
        let captured = MCPBytes(), diagnostics = MCPBytes()
        let readers = DispatchGroup()
        for (pipe, bytes) in [(output, captured), (errors, diagnostics)] {
            readers.enter()
            DispatchQueue.global().async {
                bytes.data = pipe.fileHandleForReading.readDataToEndOfFile()
                readers.leave()
            }
        }
        do {
            if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
            try stdin.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            try? stdin.fileHandleForWriting.close()
            readers.wait()
            process.waitUntilExit()
            throw error
        }
        readers.wait()
        process.waitUntilExit()
        let outputText = String(decoding: captured.data, as: UTF8.self)
        if process.terminationStatus != 0 {
            let error = String(decoding: diagnostics.data, as: UTF8.self)
            return .init(content: [.text(text: outputText + error, annotations: nil, _meta: nil)], isError: true)
        }
        if text { return .init(content: [.text(text: outputText, annotations: nil, _meta: nil)], isError: false) }
        let value = try JSONDecoder().decode(Value.self, from: captured.data)
        let structured: Value? = value.objectValue != nil ? value : .object(["data": value])
        return .init(content: [.text(text: outputText, annotations: nil, _meta: nil)], structuredContent: structured, isError: false)
    }
}

private final class MCPBytes: @unchecked Sendable {
    var data = Data()
}
