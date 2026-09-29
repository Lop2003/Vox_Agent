import Foundation

public enum AgentKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case claudeCode = "Claude Code"
    case codex = "Codex"

    public var id: String { rawValue }

    var executable: String {
        switch self {
        case .claudeCode: "claude"
        case .codex: "codex"
        }
    }
}

public enum AgentStatus: String, Codable, Sendable {
    case idle = "Idle"
    case analyzing = "Analyzing"
    case editing = "Editing"
    case testing = "Testing"
    case completed = "Completed"
    case failed = "Failed"
    case cancelled = "Cancelled"

    /// The happy-path steps shown in the status bar.
    public static let pipeline: [AgentStatus] = [.analyzing, .editing, .testing, .completed]

    /// Best guess at what a shell command is doing.
    static func forCommand(_ command: String) -> AgentStatus {
        let c = command.lowercased()
        let checks = ["test", "build", "lint", "xcodebuild", "pytest", "jest", "vitest", "tsc", "cargo check", "go vet"]
        return checks.contains { c.contains($0) } ? .testing : .analyzing
    }
}

/// Normalized events every backend is translated into, so the UI never sees backend-specific JSON.
public enum AgentEvent: Equatable, Codable, Sendable {
    case session(String)
    case status(AgentStatus)
    case activity(String)
    case message(String)
    /// Final answer. Empty means "use the last message".
    case completed(String)
    case failed(String)
}

/// A coding-agent CLI backend. Adapters only describe how to invoke the CLI and how to read its output.
public protocol CodingAgent: Sendable {
    var kind: AgentKind { get }
    func arguments(prompt: String, workspace: URL, sessionID: String?) -> [String]
    func parse(_ line: String) -> [AgentEvent]
}

#if os(macOS)
extension CodingAgent {
    public func run(prompt: String, workspace: URL, sessionID: String?) -> AsyncThrowingStream<AgentEvent, Error> {
        let lines = ProcessLines.run(kind.executable, arguments(prompt: prompt, workspace: workspace, sessionID: sessionID), cwd: workspace)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in lines {
                        for event in parse(line) { continuation.yield(event) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif

/// Runs voice requests against some agent: in-process on the Mac (`AgentSession`) or through the bridge (`BridgeClient`).
/// `onFinish` fires exactly once per `run`, after the last `onEvent`.
@MainActor
public protocol AgentRunner: AnyObject {
    /// Agent names the user can pick from, e.g. ["Claude Code", "Codex"].
    var agents: [String] { get }
    func run(_ text: String, agent: String, activeFile: String?,
             onEvent: @escaping @MainActor (AgentEvent) -> Void,
             onFinish: @escaping @MainActor (AgentStatus, String?) -> Void)
    func cancel()
    /// Forget agent sessions so the next request starts a new conversation.
    func reset()
}

public enum AgentRouter {
    public static func agent(for kind: AgentKind) -> any CodingAgent {
        switch kind {
        case .claudeCode: ClaudeCodeAgent()
        case .codex: CodexAgent()
        }
    }
}

func json(_ line: String) -> [String: Any]? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func truncate(_ s: String, _ max: Int = 120) -> String {
    let oneLine = s.replacingOccurrences(of: "\n", with: " ")
    return oneLine.count > max ? String(oneLine.prefix(max)) + "…" : oneLine
}
