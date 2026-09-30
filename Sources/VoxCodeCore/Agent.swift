import Foundation

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
}

/// Normalized agent events (produced by the bridge), so the UI never sees backend-specific JSON.
public enum AgentEvent: Equatable, Codable, Sendable {
    case session(String)
    case status(AgentStatus)
    case activity(String)
    case message(String)
    /// Final answer. Empty means "use the last message".
    case completed(String)
    case failed(String)
}

/// Runs voice requests against some agent. Today that is always the Node bridge via `BridgeClient`
/// (on the Mac through `LocalBridge`); tests can plug in fakes.
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
