import Foundation
import Testing
@testable import VoxCodeCore

@Test func promptContainsAllStructuredParts() {
    let prompt = PromptBuilder.build(AgentRequest(
        userRequest: "ช่วยดู login rate limit แล้วแก้ให้หน่อย",
        workspace: URL(fileURLWithPath: "/tmp/app"),
        projectContext: "Git branch: main",
        activeFile: "Sources/Auth.swift",
        agent: .codex,
        isFollowUp: false
    ))
    #expect(prompt.contains("> ช่วยดู login rate limit แล้วแก้ให้หน่อย"))
    #expect(prompt.contains("Path: /tmp/app"))
    #expect(prompt.contains("Git branch: main"))
    #expect(prompt.contains("Sources/Auth.swift"))
    #expect(prompt.contains("## Selected agent\nCodex"))
    #expect(prompt.contains("Do not commit or push"))
    for section in PromptBuilder.responseSections { #expect(prompt.contains("## " + section)) }
    #expect(!prompt.contains("follow-up"))
}

@Test func workspaceContextReadsBranchAndEntries() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try "ref: refs/heads/feature/x\n".write(to: dir.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
    try "".write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: dir) }

    #expect(WorkspaceContext.describe(dir) == "Git branch: feature/x\nTop-level entries: Package.swift, Sources/")
}

@Test func claudeStreamJSONParsing() {
    let agent = ClaudeCodeAgent()
    #expect(agent.parse(#"{"type":"system","subtype":"init","session_id":"s1"}"#) == [.session("s1")])
    #expect(agent.parse(#"{"type":"system","subtype":"hook_started"}"#) == [])
    #expect(agent.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"a.swift"}}]}}"#)
        == [.status(.editing), .activity("Edit a.swift")])
    #expect(agent.parse(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test"}}]}}"#)
        == [.status(.testing), .activity("$ swift test")])
    #expect(agent.parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":" hi \n"}]}}"#) == [.message("hi")])
    #expect(agent.parse(#"{"type":"result","is_error":false,"result":"done","session_id":"s1"}"#) == [.session("s1"), .completed("done")])
    #expect(agent.parse(#"{"type":"result","is_error":true,"result":"","subtype":"error_max_turns"}"#) == [.failed("error_max_turns")])
    #expect(agent.parse("not json") == [])
}

@Test func claudeArguments() {
    let args = ClaudeCodeAgent().arguments(prompt: "p", workspace: URL(fileURLWithPath: "/w"), sessionID: "s1")
    #expect(args.starts(with: ["-p", "p"]))
    #expect(args.suffix(2) == ["--resume", "s1"])
}

@Test func codexJSONParsing() {
    let agent = CodexAgent()
    #expect(agent.parse(#"{"type":"thread.started","thread_id":"t1"}"#) == [.session("t1")])
    #expect(agent.parse(#"{"type":"item.started","item":{"type":"command_execution","command":"rg login"}}"#)
        == [.status(.analyzing), .activity("$ rg login")])
    #expect(agent.parse(#"{"type":"item.completed","item":{"type":"file_change","changes":[{"path":"a.ts"},{"path":"b.ts"}]}}"#)
        == [.status(.editing), .activity("Edited a.ts, b.ts")])
    #expect(agent.parse(#"{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}"#) == [.message("ok")])
    #expect(agent.parse(#"{"type":"item.completed","item":{"type":"reasoning","text":"secret thoughts"}}"#) == [])
    #expect(agent.parse(#"{"type":"turn.completed"}"#) == [.completed("")])
    #expect(agent.parse(#"{"type":"turn.failed","error":{"message":"401"}}"#) == [.failed("401")])
}

@Test func codexArguments() {
    let w = URL(fileURLWithPath: "/w")
    #expect(CodexAgent().arguments(prompt: "p", workspace: w, sessionID: nil) == ["exec", "--json", "--skip-git-repo-check", "-s", "workspace-write", "-C", "/w", "p"])
    #expect(CodexAgent().arguments(prompt: "p", workspace: w, sessionID: "t1").suffix(2) == ["t1", "p"])
}

@Test func speakableTextUsesSummaryAndResult() {
    let reply = """
    ## Summary
    แก้ **rate limit** ใน `login` แล้ว
    ## Changed files
    - Sources/Auth.swift
    ## Result
    - Tests pass. See [docs](http://x)
    ## Remaining issues
    None
    """
    #expect(SpeechText.speakable(from: reply) == "แก้ rate limit ใน login แล้ว\nTests pass. See docs")
    #expect(SpeechText.speakable(from: "plain *answer*\n```\ncode\n```") == "plain answer")
}

@Test func lineBufferSplitsAcrossChunks() {
    let buffer = LineBuffer()
    #expect(buffer.append(Data("a\nb".utf8)) == ["a"])
    #expect(buffer.append(Data("c\n\nd".utf8)) == ["bc"])
    #expect(buffer.flush() == "d")
}

/// Real CLI round trip. Opt in with `VOXCODE_INTEGRATION=claude|codex swift test`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["VOXCODE_INTEGRATION"] != nil))
func agentRoundTrip() async throws {
    let kind: AgentKind = ProcessInfo.processInfo.environment["VOXCODE_INTEGRATION"] == "codex" ? .codex : .claudeCode
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    var events: [AgentEvent] = []
    for try await event in AgentRouter.agent(for: kind).run(prompt: "Reply with exactly: pong", workspace: dir, sessionID: nil) {
        events.append(event)
    }
    #expect(events.contains { if case .session = $0 { true } else { false } })
    #expect(events.contains { if case .message(let t) = $0 { t.lowercased().contains("pong") } else { false } })
}

@Test func pairingCodeFormatAndNormalize() {
    let code = PairingCode.generate()
    #expect(code.count == 14)
    #expect(PairingCode.normalize(code).count == 12)
    #expect(PairingCode.normalize(" abcd-efgh-jk23 ") == "ABCDEFGHJK23")
}

/// The Node bridge speaks this exact JSON (Swift's synthesized Codable); changing a case breaks it.
@Test func bridgeWireFormat() throws {
    let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    func json(_ value: some Encodable) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }

    #expect(try json(ClientMessage.run(id: id, text: "hi", agent: "Codex", activeFile: nil))
        == #"{"run":{"agent":"Codex","id":"00000000-0000-0000-0000-000000000001","text":"hi"}}"#)
    #expect(try json(ClientMessage.cancel) == #"{"cancel":{}}"#)

    let decode = { (s: String) in try JSONDecoder().decode(ServerMessage.self, from: Data(s.utf8)) }
    #expect(try decode(#"{"hello":{"workspace":"app","agents":["A","B"]}}"#) == .hello(workspace: "app", agents: ["A", "B"]))
    #expect(try decode(#"{"event":{"id":"00000000-0000-0000-0000-000000000001","event":{"status":{"_0":"Editing"}}}}"#)
        == .event(id: id, event: .status(.editing)))
    #expect(try decode(#"{"finished":{"id":"00000000-0000-0000-0000-000000000001","status":"Failed","error":"x"}}"#)
        == .finished(id: id, status: .failed, error: "x"))
    #expect(try decode(#"{"finished":{"id":"00000000-0000-0000-0000-000000000001","status":"Completed"}}"#)
        == .finished(id: id, status: .completed, error: nil))
}

@MainActor
private func waitFor(_ condition: () -> Bool) async {
    for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
}

/// Runs bridge/voxcode-bridge.mjs in a temp workspace with its own pairing code and agents.
private final class NodeBridge {
    let workspace: URL, home: URL, code: String, port: UInt16
    private let process = Process()

    init(agents: String? = nil) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        workspace = root.appendingPathComponent("ws")
        home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        code = PairingCode.generate()
        port = UInt16.random(in: 50000...60000)
        try code.write(to: home.appendingPathComponent("pairing-code"), atomically: true, encoding: .utf8)
        if let agents { try agents.write(to: home.appendingPathComponent("agents.json"), atomically: true, encoding: .utf8) }

        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../bridge/voxcode-bridge.mjs").standardizedFileURL
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path, "--workspace", workspace.path, "--port", String(port)]
        var env = ProcessInfo.processInfo.environment
        env["VOXCODE_HOME"] = home.path
        env["PATH"] = searchPath
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        Thread.sleep(forTimeInterval: 0.8) // let it bind
    }

    deinit {
        process.terminate()
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }
}

private let searchPath = (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:" + NSString(string: "~/.local/bin").expandingTildeInPath
private let nodeAvailable = searchPath.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/node") }

@MainActor @Test(.enabled(if: nodeAvailable))
func nodeBridgePairingRunAndCancel() async throws {
    // Agents point at fake CLIs so the test needs no network or API usage.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func script(_ name: String, _ body: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
    let fast = try script("fast", """
    printf '%s\n' '{"type":"system","subtype":"init","session_id":"s1"}'
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"ดูโค้ดก่อน"},{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}'
    printf '%s\n' '{"type":"result","is_error":false,"result":"## Summary\\npong","session_id":"s1"}'
    """)
    let slow = try script("slow", "sleep 30")
    let bridge = try NodeBridge(agents: """
    [{"name":"Fast","cli":"claude","command":"\(fast)"},{"name":"Slow","cli":"claude","command":"\(slow)"}]
    """)

    let wrong = BridgeClient()
    wrong.connect(pairingCode: PairingCode.generate(), host: "127.0.0.1", port: bridge.port)
    await waitFor { if case .failed = wrong.state { true } else { false } }
    #expect(!wrong.isConnected)

    let client = BridgeClient()
    client.connect(pairingCode: bridge.code.lowercased(), host: "127.0.0.1", port: bridge.port)
    await waitFor { client.isConnected }
    #expect(client.state == .connected(workspace: "ws"))
    #expect(client.agents == ["Fast", "Slow"])

    var events: [AgentEvent] = []
    var result: (AgentStatus, String?)?
    client.run("ping", agent: "Fast", activeFile: nil, onEvent: { events.append($0) }, onFinish: { result = ($0, $1) })
    await waitFor { result != nil }
    #expect(result?.0 == .completed)
    #expect(events.contains(.message("ดูโค้ดก่อน")))
    #expect(events.contains(.status(.testing)))
    #expect(events.contains(.completed("## Summary\npong")))

    // Cancelling finishes locally at once; the bridge's late reply is dropped by request id.
    var finished: [AgentStatus] = []
    client.run("wait", agent: "Slow", activeFile: nil, onEvent: { _ in }, onFinish: { status, _ in finished.append(status) })
    try await Task.sleep(for: .milliseconds(300))
    client.cancel()
    try await Task.sleep(for: .milliseconds(300))
    #expect(finished == [.cancelled])

    // The bridge is free again after the cancel.
    result = nil
    client.run("again", agent: "Fast", activeFile: nil, onEvent: { _ in }, onFinish: { result = ($0, $1) })
    await waitFor { result != nil }
    #expect(result?.0 == .completed)

    // Unknown agents fail cleanly.
    result = nil
    client.run("x", agent: "Nope", activeFile: nil, onEvent: { _ in }, onFinish: { result = ($0, $1) })
    await waitFor { result != nil }
    #expect(result?.0 == .failed)
    client.disconnect()
}

/// App client → Node bridge → real CLI. Opt in with `VOXCODE_INTEGRATION=claude|codex swift test`.
@MainActor @Test(.enabled(if: nodeAvailable && ProcessInfo.processInfo.environment["VOXCODE_INTEGRATION"] != nil))
func nodeBridgeRealAgent() async throws {
    let agent = ProcessInfo.processInfo.environment["VOXCODE_INTEGRATION"] == "codex" ? "Codex" : "Claude Code"
    let bridge = try NodeBridge()
    let client = BridgeClient()
    client.connect(pairingCode: bridge.code, host: "127.0.0.1", port: bridge.port)
    await waitFor { client.isConnected }

    var messages: [String] = []
    var result: AgentStatus?
    client.run("Reply with exactly: pong", agent: agent, activeFile: nil,
               onEvent: { if case .message(let t) = $0 { messages.append(t) } },
               onFinish: { status, _ in result = status })
    for _ in 0..<1200 where result == nil { try await Task.sleep(for: .milliseconds(100)) }
    #expect(result == .completed)
    #expect(messages.contains { $0.lowercased().contains("pong") })
}
