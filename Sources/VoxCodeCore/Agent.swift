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

/// A set of agents for one kind of work: the project folder ("code") or everyday questions ("general").
public struct AgentWorkspace: Codable, Equatable, Identifiable, Sendable {
    public static let code = "code", general = "general"
    public let id: String
    public let name: String
    public let agents: [String]

    public init(id: String, name: String, agents: [String]) {
        self.id = id
        self.name = name
        self.agents = agents
    }
}

/// Runs voice requests against some agent. Today that is always the Node bridge via `BridgeClient`
/// (on the Mac through `LocalBridge`); tests can plug in fakes.
/// `onFinish` fires exactly once per `run`, after the last `onEvent`.
@MainActor
public protocol AgentRunner: AnyObject {
    /// Agent names the user can pick from, e.g. ["Claude Code", "Codex"].
    var agents: [String] { get }
    /// The workspaces the user can switch between, each with its own agents.
    var workspaces: [AgentWorkspace] { get }
    func run(_ text: String, agent: String, activeFile: String?, language: String?,
             onEvent: @escaping @MainActor (AgentEvent) -> Void,
             onFinish: @escaping @MainActor (AgentStatus, String?) -> Void)
    func cancel()
    /// Forget agent sessions so the next request starts a new conversation.
    func reset()
}

public extension AgentRunner {
    /// Runners that don't know about workspaces: everything is the project workspace.
    var workspaces: [AgentWorkspace] { [AgentWorkspace(id: AgentWorkspace.code, name: "Workspace", agents: agents)] }
}
