import Foundation

public struct AgentRequest: Sendable {
    public var userRequest: String
    public var workspace: URL
    public var projectContext: String
    public var activeFile: String?
    public var agent: AgentKind
    public var isFollowUp: Bool

    public init(userRequest: String, workspace: URL, projectContext: String, activeFile: String?, agent: AgentKind, isFollowUp: Bool) {
        self.userRequest = userRequest
        self.workspace = workspace
        self.projectContext = projectContext
        self.activeFile = activeFile
        self.agent = agent
        self.isFollowUp = isFollowUp
    }
}

/// Turns a raw (possibly mis-transcribed) voice request into a structured agent prompt.
public enum PromptBuilder {
    public static let responseSections = ["Summary", "Changed files", "Checks", "Result", "Remaining issues"]

    public static func build(_ r: AgentRequest) -> String {
        """
        # Vox Agent request\(r.isFollowUp ? " (follow-up in the same conversation)" : "")

        ## User request
        Spoken by the user and converted with speech-to-text, so it may be informal, incomplete, or contain recognition errors:
        > \(r.userRequest.replacingOccurrences(of: "\n", with: "\n> "))

        ## Workspace
        Path: \(r.workspace.path)
        \(r.projectContext)

        ## Active file
        \(r.activeFile ?? "None")

        ## Selected agent
        \(r.agent.rawValue)

        ## How to work
        You are a software engineering agent working in the workspace above. Inspect the codebase to work out what the user means instead of interpreting the transcription literally. If the request is still ambiguous, state the assumption you made.
        - Before modifying code: inspect the repository, understand the relevant architecture, identify the root cause, reuse existing patterns and utilities, avoid unrelated changes.
        - When implementing: make the smallest appropriate change, follow the project's conventions, do not invent APIs, schemas, business rules or requirements, add or update tests when appropriate.
        - After implementing: run the relevant tests, builds or linters and review the git diff.
        - Before each major step, write one short sentence in the user's language saying what you are about to do; the user may be listening instead of reading.

        ## Constraints
        - Never expose secrets, credentials, API keys, tokens or private keys.
        - Do not delete files or data unless the user explicitly asked for it.
        - Do not run destructive operations (rm -rf, git reset --hard, force push, dropping data); stop and ask for confirmation instead.
        - Do not commit or push unless the user explicitly asked for it.
        - Report conclusions only; do not include internal reasoning.

        ## Response format
        Reply in the language of the user request. Use exactly these Markdown headings, in English:
        \(responseSections.map { "## " + $0 }.joined(separator: "\n"))
        Keep Summary to 1–3 short sentences because it is read aloud. For a plain question, answer under Summary and write "None" in the other sections.
        """
    }
}

public enum WorkspaceContext {
    /// Cheap context the agent can't know from the prompt alone: git branch and top-level layout.
    public static func describe(_ workspace: URL, maxEntries: Int = 50) -> String {
        let fm = FileManager.default
        var branch = "not a git repository"
        if let head = try? String(contentsOf: workspace.appendingPathComponent(".git/HEAD"), encoding: .utf8) {
            let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
            branch = trimmed.hasPrefix("ref: refs/heads/") ? String(trimmed.dropFirst("ref: refs/heads/".count)) : "detached at \(trimmed.prefix(12))"
        }
        let entries = ((try? fm.contentsOfDirectory(at: workspace, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? [])
            .map { url in
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                return url.lastPathComponent + (isDir ? "/" : "")
            }
            .sorted()
        let listed = entries.prefix(maxEntries).joined(separator: ", ") + (entries.count > maxEntries ? ", …" : "")
        return "Git branch: \(branch)\nTop-level entries: \(listed.isEmpty ? "(empty)" : listed)"
    }
}
