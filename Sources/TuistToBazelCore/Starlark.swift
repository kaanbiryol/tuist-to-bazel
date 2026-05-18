import Foundation

enum Starlark {
    static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    static func list(_ values: [String], indent: Int = 4) -> String {
        orderedList(values.sorted(), indent: indent)
    }

    static func orderedList(_ values: [String], indent: Int = 4) -> String {
        if values.isEmpty {
            return "[]"
        }

        let padding = String(repeating: " ", count: indent)
        let itemPadding = String(repeating: " ", count: indent + 4)
        let body = values.map { "\(itemPadding)\(quote($0))," }.joined(separator: "\n")
        return "[\n\(body)\n\(padding)]"
    }

    static func exprList(_ expressions: [String], indent: Int = 4) -> String {
        if expressions.isEmpty {
            return "[]"
        }
        return expressions.sorted().map { expression in
            expression.hasPrefix("glob(") ? expression : "[\(expression)]"
        }.joined(separator: " + ")
    }
}

struct BuildFile {
    private var lines: [String] = []

    mutating func add(_ line: String = "") {
        lines.append(line)
    }

    mutating func addBlock(_ block: String) {
        lines.append(block.trimmingCharacters(in: .newlines))
    }

    var content: String {
        lines.joined(separator: "\n") + "\n"
    }
}
