#if os(macOS)
import Foundation

/// Runs agent CLIs in one workspace on this Mac, remembering each agent's session for follow-ups.
@MainActor
public final class AgentSession: AgentRunner {
    public let workspace: URL
    // ponytail: fixed 15 min agent timeout; make it a setting if long refactors hit it.
    public var timeout: Duration = .seconds(15 * 60)

    private var sessions: [AgentKind: String] = [:]
    private var task: Task<Void, Never>?
    private var onFinish: (@MainActor (AgentStatus, String?) -> Void)?

    public init(workspace: URL) {
        self.workspace = workspace
    }

    public var isRunning: Bool { onFinish != nil }

    public var agents: [String] { AgentKind.allCases.map(\.rawValue) }

    public func run(_ text: String, agent: String, activeFile: String?,
                    onEvent: @escaping @MainActor (AgentEvent) -> Void,
                    onFinish: @escaping @MainActor (AgentStatus, String?) -> Void) {
        guard !isRunning else { return onFinish(.failed, "The agent is already running.") }
        guard let kind = AgentKind(rawValue: agent) else { return onFinish(.failed, "Unknown agent: \(agent)") }
        self.onFinish = onFinish

        let prompt = PromptBuilder.build(AgentRequest(
            userRequest: text,
            workspace: workspace,
            projectContext: WorkspaceContext.describe(workspace),
            activeFile: activeFile,
            agent: kind,
            isFollowUp: sessions[kind] != nil
        ))
        let stream = AgentRouter.agent(for: kind).run(prompt: prompt, workspace: workspace, sessionID: sessions[kind])
        let timeout = timeout
        task = Task { [weak self] in
            let timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled { self?.finish(.failed, "Timed out after \(timeout.components.seconds / 60) minutes.") }
            }
            defer { timer.cancel() }
            do {
                for try await event in stream {
                    guard let self, self.isRunning else { return }
                    switch event {
                    case .session(let id): self.sessions[kind] = id
                    case .failed(let message): return self.finish(.failed, message)
                    default: onEvent(event)
                    }
                    if case .completed = event { return self.finish(.completed) }
                }
                self?.finish(.completed)
            } catch {
                self?.finish(.failed, error.localizedDescription)
            }
        }
    }

    public func cancel() { finish(.cancelled) }

    public func reset() {
        cancel()
        sessions = [:]
    }

    /// Ends the run exactly once, whichever of completion, failure, timeout or cancel comes first.
    private func finish(_ status: AgentStatus, _ error: String? = nil) {
        guard let onFinish else { return }
        self.onFinish = nil
        task?.cancel() // terminates the CLI process if it is still running
        task = nil
        onFinish(status, error)
    }
}
#endif
