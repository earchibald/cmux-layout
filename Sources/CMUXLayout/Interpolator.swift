import Foundation

public struct Interpolator: Sendable {
    public static func resolve(
        _ input: String,
        environment: [String: String]? = nil
    ) -> String {
        let env = environment ?? ProcessInfo.processInfo.environment
        var result = ""
        var i = input.startIndex

        while i < input.endIndex {
            if input[i] == "$" {
                let next = input.index(after: i)

                if next < input.endIndex && input[next] == "$" {
                    result.append("$")
                    i = input.index(after: next)
                    continue
                }

                if next < input.endIndex && input[next] == "{" {
                    let braceStart = input.index(after: next)
                    if let braceEnd = input[braceStart...].firstIndex(of: "}") {
                        let content = String(input[braceStart..<braceEnd])
                        if let sepRange = content.range(of: ":-") {
                            let varName = String(content[content.startIndex..<sepRange.lowerBound])
                            let defaultVal = String(content[sepRange.upperBound...])
                            let value = env[varName]
                            result.append((value?.isEmpty == false) ? value! : defaultVal)
                        } else {
                            result.append(env[content] ?? "")
                        }
                        i = input.index(after: braceEnd)
                        continue
                    }
                }

                if next < input.endIndex && (input[next].isLetter || input[next] == "_") {
                    var end = next
                    while end < input.endIndex && (input[end].isLetter || input[end].isNumber || input[end] == "_") {
                        end = input.index(after: end)
                    }
                    let varName = String(input[next..<end])
                    result.append(env[varName] ?? "")
                    i = end
                    continue
                }

                result.append("$")
                i = next
                continue
            }

            result.append(input[i])
            i = input.index(after: i)
        }

        return result
    }
}
