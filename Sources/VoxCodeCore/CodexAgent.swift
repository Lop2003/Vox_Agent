import Foundation

/// `codex exec --json`.
public struct CodexAgent: CodingAgent {
    public let kind = AgentKind.codex

    public init() {}

    public func arguments(prompt: String, workspace: URL, sessionID: String?) -> [String] {
        if let sessionID {
            // `exec resume` has no -s/-C flags: sandbox goes through config, workspace through cwd.
            return ["exec", "resume", "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"workspace-write\"", sessionID, prompt]
        }
        return ["exec", "--json", "--skip-git-repo-check", "-s", "workspace-write", "-C", workspace.path, prompt]
    }

    public func parse(_ line: String) -> [AgentEvent] {
        guard let obj = json(line), let type = obj["type"] as? String else { return [] }
        let item = obj["item"] as? [String: Any] ?? [:]
        let itemType = item["type"] as? String

        switch (type, itemType) {
        case ("thread.started", _):
            return (obj["thread_id"] as? String).map { [.session($0)] } ?? []
        case ("turn.started", _):
            return [.status(.analyzing)]
        case ("item.started", "command_execution"):
            let command = item["command"] as? String ?? ""
            return [.status(AgentStatus.forCommand(command)), .activity("$ " + truncate(command))]
        case ("item.completed", "agent_message"):
            let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.message(text)]
        case ("item.completed", "file_change"):
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            return [.status(.editing), .activity("Edited " + truncate(paths.joined(separator: ", ")))]
        case ("turn.completed", _):
            return [.completed("")]
        case ("turn.failed", _):
            let message = (obj["error"] as? [String: Any])?["message"] as? String ?? "Codex turn failed"
            return [.failed(message)]
        case ("error", _):
            // Transient (e.g. reconnect attempts); a real failure also arrives as turn.failed.
            return (obj["message"] as? String).map { [.activity("⚠︎ " + truncate($0))] } ?? []
        default:
            // Reasoning items are deliberately dropped: never surface hidden chain-of-thought.
            return []
        }
    }
}
