import Foundation

/// Picks the part of an agent reply worth reading aloud and strips Markdown noise.
public enum SpeechText {
    public static func speakable(from markdown: String) -> String {
        let parts = ["Summary", "Result"].compactMap { section($0, in: markdown) }
            .filter { !$0.isEmpty && $0.lowercased() != "none" }
        return strip(parts.isEmpty ? markdown : parts.joined(separator: "\n"))
    }

    static func section(_ name: String, in markdown: String) -> String? {
        var lines: [String]?
        for line in markdown.components(separatedBy: .newlines) {
            if line.hasPrefix("#") {
                if lines != nil { break }
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if title.caseInsensitiveCompare(name) == .orderedSame { lines = [] }
            } else {
                lines?.append(line)
            }
        }
        return lines?.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func strip(_ text: String) -> String {
        var kept: [String] = []
        var inCode = false
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            if !inCode { kept.append(line) }
        }
        return kept.joined(separator: "\n")
            .replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\s*[-*+]\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*`#>]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
