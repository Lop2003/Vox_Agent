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

/// How much the coding agent may do on its own.
public enum PermissionMode: String, Codable, CaseIterable, Sendable {
    /// The app confirms every request that would change files; Claude may edit files but not run shell commands.
    case manual
    /// The app confirms spoken change requests; the agent's own safety checks approve safe actions.
    case auto
    /// No confirmation and no agent sandbox: it can run anything on this Mac.
    case full
}

/// How hard the model thinks (Claude `--effort`, Codex `model_reasoning_effort`). `standard` keeps the CLI's default.
public enum Effort: String, Codable, CaseIterable, Sendable {
    case standard = "default", low, medium, high, max
}

/// One request to an agent.
public struct AgentRequest: Equatable, Sendable {
    public var text: String
    public var agent: String
    public var activeFile: String?
    /// The app's speech language (e.g. "th-TH"); the agent is told to reply in it.
    public var language: String?
    public var mode: PermissionMode
    public var effort: Effort

    public init(text: String, agent: String, activeFile: String? = nil, language: String? = nil,
                mode: PermissionMode = .auto, effort: Effort = .standard) {
        self.text = text
        self.agent = agent
        self.activeFile = activeFile
        self.language = language
        self.mode = mode
        self.effort = effort
    }
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
    func run(_ request: AgentRequest,
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
