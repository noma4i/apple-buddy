import Foundation

func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    let characters = Array(text)
    var index = 0
    while index < characters.count {
        let character = characters[index]
        if quoted {
            if character == "\"" {
                if index + 1 < characters.count, characters[index + 1] == "\"" {
                    field.append("\"")
                    index += 1
                } else {
                    quoted = false
                }
            } else {
                field.append(character)
            }
        } else {
            switch character {
            case "\"": quoted = true
            case ",":
                row.append(field)
                field = ""
            case "\n", "\r\n":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default: field.append(character)
            }
        }
        index += 1
    }
    if !field.isEmpty || !row.isEmpty {
        row.append(field)
        rows.append(row)
    }
    return rows
}
