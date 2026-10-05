import ArgumentParser
import Foundation

struct TableOption: ParsableArguments {
    @Option(name: .customLong("table"), help: "Table number in the note, counted from 1") var index = 1
}

struct Tables: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "table",
        abstract: "Create tables and edit their cells, rows and columns",
        discussion: """
        Rows, columns and tables are counted from 1, left to right and top to bottom.
        Edits the native table while preserving attachments, links and tags.

        EXAMPLES
          nb table new <id> --csv data.csv
          nb table ls <id>
          nb table set <id> --row 2 --col 1 --value "Done"
          nb table add-row <id> --at 2
        """,
        subcommands: [TableList.self, TableNew.self, TableSet.self, TableAddRow.self, TableRemoveRow.self, TableAddColumn.self, TableRemoveColumn.self]
    )
}

private func editTable(id: String, table: TableOption, operation: String, output: OutputOptions, values: [String: Any] = [:]) throws {
    var options = values
    options["table"] = table.index
    try output.writeAction(operation.replacingOccurrences(of: "table-", with: "table "), openLocalNotes(readOnly: false).editNote(id, operation: operation, options: options), text: id)
}

struct TableList: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "Print the tables of a note",
        discussion: """
        Prints each table as tab-separated rows under a "# table N" line.
        With --json prints an array of tables, each one an array of rows.

        EXAMPLE
          nb table ls <id> --json
        """
    )

    @Argument(help: "Note id from `ls` or `new`") var id: String

    func run() throws {
        let result = try openLocalNotes(readOnly: true).readNote(id)
        guard let tables = result["tables"] as? [[[String]]] else { throw NotesError(description: "Notes returned invalid table data") }
        let text = tables.enumerated().map { number, grid in
            let rows = grid.map { $0.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }
            return (["# table \(number + 1)"] + rows).joined(separator: "\n")
        }.joined(separator: "\n")
        try output.write(tables, text: text)
    }
}

struct TableNew: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Add a table to the end of a note",
        discussion: """
        Fill the table from a CSV file, or from stdin with `-`, or create an empty
        grid with --size ROWSxCOLUMNS. Give exactly one of the two.

        EXAMPLES
          nb table new <id> --csv data.csv
          nb table new <id> --size 3x2
        """
    )

    @Argument(help: "Note id from `ls` or `new`") var id: String
    @Option(help: "CSV file, - for stdin") var csv: String?
    @Option(help: "Empty table size as ROWSxCOLUMNS, for example 3x2") var size: String?

    func run() throws {
        let grid: [[String]]
        switch (csv, size) {
        case let (path?, nil):
            grid = parseCSV(try readHTML(from: path))
        case let (nil, spec?):
            let parts = spec.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { throw ValidationError("--size must look like 3x2") }
            grid = Array(repeating: Array(repeating: "", count: parts[1]), count: parts[0])
        default:
            throw ValidationError("give exactly one of --csv and --size")
        }
        guard !grid.isEmpty else { throw NotesError(description: "the CSV has no rows") }
        try output.writeAction("table new", openLocalNotes(readOnly: false).editNote(id, operation: "table-new", options: ["rows": grid.count, "columns": grid.map(\.count).max() ?? 0, "grid": grid]), text: id)
    }
}

struct TableSet: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Change the text of one cell",
        discussion: """
        Replaces the whole text of the cell. Other cells and the rest of the note stay as they are.

        EXAMPLE
          nb table set <id> --row 2 --col 1 --value "Done"
        """
    )

    @Argument(help: "Note id from `ls` or `new`") var id: String
    @OptionGroup var table: TableOption
    @Option(help: "Row number") var row: Int
    @Option(help: "Column number") var col: Int
    @Option(help: "New cell text, plain text") var value: String

    func run() throws {
        try editTable(id: id, table: table, operation: "table-set", output: output, values: ["row": row, "column": col, "value": value])
    }
}

struct TableAddRow: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "add-row",
        abstract: "Insert an empty row",
        discussion: """
        Without --at the row goes to the end. With --at N it becomes row N.

        EXAMPLE
          nb table add-row <id> --at 2
        """
    )

    @Argument(help: "Note id from `ls` or `new`") var id: String
    @OptionGroup var table: TableOption
    @Option(help: "Position of the new row") var at: Int?

    func run() throws {
        try editTable(id: id, table: table, operation: "table-add-row", output: output, values: at.map { ["at": $0] } ?? [:])
    }
}

struct TableRemoveRow: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "rm-row",
        abstract: "Delete a row",
        discussion: """
        Refuses to delete the only row of a table.

        EXAMPLE
          nb table rm-row <id> --row 3
        """
    )

    @Argument(help: "Note id from `ls` or `new`") var id: String
    @OptionGroup var table: TableOption
    @Option(help: "Row number to delete") var row: Int

    func run() throws {
        try editTable(id: id, table: table, operation: "table-rm-row", output: output, values: ["at": row])
    }
}

struct TableAddColumn: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "add-col",
        abstract: "Insert an empty column",
        discussion: """
        Without --at the column goes to the end. With --at N it becomes column N.

        EXAMPLE
          nb table add-col <id> --at 1
        """
    )

    @Argument(help: "Note id from `ls` or `new`") var id: String
    @OptionGroup var table: TableOption
    @Option(help: "Position of the new column") var at: Int?

    func run() throws {
        try editTable(id: id, table: table, operation: "table-add-col", output: output, values: at.map { ["at": $0] } ?? [:])
    }
}

struct TableRemoveColumn: ParsableCommand {
    @OptionGroup var output: OutputOptions
    static let configuration = CommandConfiguration(
        commandName: "rm-col",
        abstract: "Delete a column",
        discussion: """
        Refuses to delete the only column of a table.

        EXAMPLE
          nb table rm-col <id> --col 2
        """
    )

    @Argument(help: "Note id from `ls` or `new`") var id: String
    @OptionGroup var table: TableOption
    @Option(help: "Column number to delete") var col: Int

    func run() throws {
        try editTable(id: id, table: table, operation: "table-rm-col", output: output, values: ["at": col])
    }
}
