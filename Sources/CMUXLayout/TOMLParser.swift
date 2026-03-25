import Foundation

public enum TOMLEntry: Equatable, Sendable {
    case blank
    case comment(String)
    case table(String)
    case keyValue(String, String)
}

public struct TOMLDocument: Equatable, Sendable {
    public var entries: [TOMLEntry]

    public init(entries: [TOMLEntry] = []) {
        self.entries = entries
    }
}

public enum TOMLError: Error, Equatable {
    case unterminatedString(Int)
    case invalidLine(Int, String)
    case unsupportedFeature(Int, String)
}

public struct TOMLParser: Sendable {
    public init() {}

    public static func parse(_ input: String) throws -> TOMLDocument {
        guard !input.isEmpty else {
            return TOMLDocument()
        }
        let lines = input.components(separatedBy: "\n")
        var entries: [TOMLEntry] = []

        for (lineIndex, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .init(charactersIn: "\r"))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lineNum = lineIndex + 1

            if trimmed.isEmpty {
                entries.append(.blank)
                continue
            }

            if trimmed.hasPrefix("#") {
                entries.append(.comment(line))
                continue
            }

            if trimmed.hasPrefix("[") {
                if trimmed.hasPrefix("[[") {
                    throw TOMLError.unsupportedFeature(lineNum, "arrays-of-tables ([[...]])")
                }
                guard let close = trimmed.firstIndex(of: "]") else {
                    throw TOMLError.invalidLine(lineNum, line)
                }
                let name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else {
                    throw TOMLError.invalidLine(lineNum, line)
                }
                entries.append(.table(name))
                continue
            }

            guard let eqIndex = trimmed.firstIndex(of: "=") else {
                throw TOMLError.invalidLine(lineNum, line)
            }
            let key = String(trimmed[trimmed.startIndex..<eqIndex])
                .trimmingCharacters(in: .whitespaces)
            guard isValidBareKey(key) else {
                throw TOMLError.invalidLine(lineNum, line)
            }
            let afterEq = String(trimmed[trimmed.index(after: eqIndex)...])
                .trimmingCharacters(in: .whitespaces)
            let value = try parseStringValue(afterEq, lineNum: lineNum)
            entries.append(.keyValue(key, value))
        }

        // Remove spurious trailing blank produced by split when input ends with newline
        if input.hasSuffix("\n"), let last = entries.last, case .blank = last {
            entries.removeLast()
        }

        return TOMLDocument(entries: entries)
    }

    public static func serialize(_ doc: TOMLDocument) -> String {
        guard !doc.entries.isEmpty else { return "" }
        var lines: [String] = []
        for entry in doc.entries {
            switch entry {
            case .blank:
                lines.append("")
            case .comment(let text):
                lines.append(text)
            case .table(let name):
                lines.append("[\(name)]")
            case .keyValue(let key, let value):
                lines.append("\(key) = \"\(escapeString(value))\"")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func escapeString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func isValidBareKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    private static func parseStringValue(_ raw: String, lineNum: Int) throws -> String {
        var s = raw
        guard s.hasPrefix("\"") else {
            if s == "true" || s == "false" {
                throw TOMLError.unsupportedFeature(lineNum, "boolean values")
            }
            if s.first?.isNumber == true || s.first == "-" || s.first == "+" {
                throw TOMLError.unsupportedFeature(lineNum, "numeric values")
            }
            if s.hasPrefix("[") {
                throw TOMLError.unsupportedFeature(lineNum, "array values")
            }
            if s.hasPrefix("{") {
                throw TOMLError.unsupportedFeature(lineNum, "inline table values")
            }
            throw TOMLError.invalidLine(lineNum, raw)
        }
        s.removeFirst()

        var result = ""
        var escaped = false
        var closed = false
        for ch in s {
            if escaped {
                switch ch {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append("\\"); result.append(ch)
                }
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                closed = true
                break
            } else {
                result.append(ch)
            }
        }
        guard closed else {
            throw TOMLError.unterminatedString(lineNum)
        }
        return result
    }
}
