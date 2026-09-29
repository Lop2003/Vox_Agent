import Foundation

/// `claude -p --output-format stream-json`.
public struct ClaudeCodeAgent: CodingAgent {
    public let kind = AgentKind.claudeCode

    public init() {}

    public func arguments(prompt: String, workspace: URL, sessionID: String?) -> [String] {
        // ponytail: "auto" lets Claude Code's classifier approve safe tools headlessly; add a
        // permission picker if users need stricter ("acceptEdits") or looser modes.
        var args = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--permission-mode", "auto"]
        if let sessionID { args += ["--resume", sessionID] }
        return args
    }

    public func parse(_ line: String) -> [AgentEvent] {
        guard let obj = json(line), let type = obj["type"] as? String else { return [] }
        switch type {
        case "system" where obj["subtype"] as? String == "init":
            return (obj["session_id"] as? String).map { [.session($0)] } ?? []

        case "assistant":
            let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.flatMap { item -> [AgentEvent] in
                switch item["type"] as? String {
                case "text":
                    let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? [] : [.message(text)]
                case "tool_use":
                    let name = item["name"] as? String ?? "Tool"
                    let input = item["input"] as? [String: Any] ?? [:]
                    return [.status(Self.status(tool: name, input: input)), .activity(Self.describe(tool: name, input: input))]
                default:
                    return []
                }
            }

        case "result":
            var events: [AgentEvent] = (obj["session_id"] as? String).map { [.session($0)] } ?? []
            let result = obj["result"] as? String ?? ""
            if obj["is_error"] as? Bool == true {
                events.append(.failed(result.isEmpty ? (obj["subtype"] as? String ?? "Claude Code failed") : result))
            } else {
                events.append(.completed(result))
            }
            return events

        default:
            return []
        }
    }

    static func status(tool: String, input: [String: Any]) -> AgentStatus {
        switch tool {
        case "Edit", "MultiEdit", "Write", "NotebookEdit": .editing
        case "Bash": AgentStatus.forCommand(input["command"] as? String ?? "")
        default: .analyzing
        }
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        if tool == "Bash", let command = input["command"] as? String { return "$ " + truncate(command) }
        let detail = ["file_path", "pattern", "path", "url", "description"].lazy.compactMap { input[$0] as? String }.first
        return detail.map { "\(tool) \(truncate($0))" } ?? tool
    }
}
