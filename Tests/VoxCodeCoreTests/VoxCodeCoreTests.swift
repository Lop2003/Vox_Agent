import Foundation
import Testing
@testable import VoxCodeCore

// Agent CLI parsing and prompt building live in the Node bridge: see bridge/voxcode-bridge.test.mjs.

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

    #expect(try json(ClientMessage.run(id: id, text: "hi", agent: "Codex", activeFile: nil, language: "th-TH", mode: "full", effort: "high", model: "gpt-6-sol", interrupted: "แสง"))
        == #"{"run":{"agent":"Codex","effort":"high","id":"00000000-0000-0000-0000-000000000001","interrupted":"แสง","language":"th-TH","mode":"full","model":"gpt-6-sol","text":"hi"}}"#)
    #expect(try json(ClientMessage.cancel) == #"{"cancel":{}}"#)

    let decode = { (s: String) in try JSONDecoder().decode(ServerMessage.self, from: Data(s.utf8)) }
    #expect(try decode(#"{"hello":{"workspace":"app","agents":["A","B"],"speech":true,"workspaces":[{"id":"code","name":"app","agents":["A"]},{"id":"general","name":"General","agents":["B"]}]}}"#)
        == .hello(workspace: "app", agents: ["A", "B"], speech: true, workspaces: [
            AgentWorkspace(id: "code", name: "app", agents: ["A"]), AgentWorkspace(id: "general", name: "General", agents: ["B"]),
        ], models: nil))
    // Older bridges don't send "speech" or "workspaces".
    #expect(try decode(#"{"hello":{"workspace":"app","agents":["A"]}}"#) == .hello(workspace: "app", agents: ["A"], speech: nil, workspaces: nil, models: nil))
    #expect(try decode(#"{"hello":{"workspace":"app","agents":["Codex"],"models":{"Codex":[{"id":"gpt-6-sol","name":"GPT-6-Sol"}]}}}"#)
        == .hello(workspace: "app", agents: ["Codex"], speech: nil, workspaces: nil, models: ["Codex": [AgentModel(id: "gpt-6-sol", name: "GPT-6-Sol")]]))
    #expect(try decode(#"{"audio":{"id":"00000000-0000-0000-0000-000000000001","data":"AAEC"}}"#) == .audio(id: id, data: Data([0, 1, 2]), error: nil))
    #expect(try decode(#"{"audio":{"id":"00000000-0000-0000-0000-000000000001","error":"no"}}"#) == .audio(id: id, data: nil, error: "no"))
    #expect(try json(ClientMessage.speak(id: id, text: "hi")) == #"{"speak":{"id":"00000000-0000-0000-0000-000000000001","text":"hi"}}"#)
    #expect(try decode(#"{"event":{"id":"00000000-0000-0000-0000-000000000001","event":{"status":{"_0":"Editing"}}}}"#)
        == .event(id: id, event: .status(.editing)))
    #expect(try decode(#"{"finished":{"id":"00000000-0000-0000-0000-000000000001","status":"Failed","error":"x"}}"#)
        == .finished(id: id, status: .failed, error: "x"))
    #expect(try decode(#"{"finished":{"id":"00000000-0000-0000-0000-000000000001","status":"Completed"}}"#)
        == .finished(id: id, status: .completed, error: nil))
}

@MainActor
private func waitFor(seconds: Double = 5, _ condition: () -> Bool) async {
    for _ in 0..<Int(seconds * 20) where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
}

private let searchPath = (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":" + LocalBridge.extraPaths.joined(separator: ":")
private let nodeAvailable = searchPath.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/node") }
private let bridgeScript = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../bridge/voxcode-bridge.mjs").standardizedFileURL

/// Temp workspace + bridge home, and fake agent CLIs so tests need no network or API usage.
private final class Sandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    var workspace: URL { root.appendingPathComponent("ws") }
    var home: URL { root.appendingPathComponent("home") }

    init() throws {
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    func script(_ name: String, _ body: String) throws -> String {
        let url = root.appendingPathComponent(name)
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func agents(_ json: String) throws -> URL {
        let url = root.appendingPathComponent("agents.json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func bridge(port: UInt16? = nil, agents: URL? = nil) throws -> LocalBridge {
        try LocalBridge(script: bridgeScript, workspace: workspace, home: home, port: port, agentsFile: agents)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

@MainActor @Test(.enabled(if: nodeAvailable))
func bridgePairingRunAndCancel() async throws {
    let box = try Sandbox()
    let fast = try box.script("fast", """
    printf '%s\\n' '{"type":"system","subtype":"init","session_id":"s1"}'
    printf '%s\\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"ดูโค้ดก่อน"},{"type":"tool_use","name":"Bash","input":{"command":"npm test"}}]}}'
    printf '%s\\n' '{"type":"result","is_error":false,"result":"## Summary\\npong","session_id":"s1"}'
    """)
    let slow = try box.script("slow", "sleep 30")
    let bridge = try box.bridge(agents: box.agents("""
    [{"name":"Fast","cli":"claude","command":"\(fast)"},{"name":"Slow","cli":"claude","command":"\(slow)"}]
    """))
    defer { bridge.stop() }

    // A wrong code is an auth failure: reported once, no endless retries.
    let wrong = BridgeClient()
    wrong.connect(pairingCode: PairingCode.generate(), host: "127.0.0.1", port: bridge.port)
    await waitFor { if case .failed = wrong.state { true } else { false } }
    guard case .failed = wrong.state else { Issue.record("wrong code should fail, got \(wrong.state)"); return }
    try await Task.sleep(for: .seconds(1.5))
    if case .failed = wrong.state {} else { Issue.record("wrong code must not retry, got \(wrong.state)") }

    let client = BridgeClient()
    client.connect(pairingCode: bridge.pairingCode.lowercased(), host: "127.0.0.1", port: bridge.port)
    await waitFor { client.isConnected }
    #expect(client.state == .connected(workspace: "ws"))
    #expect(client.agents == ["Fast", "Slow", "Claude"]) // the default General agent is added
    #expect(client.workspaces == [
        AgentWorkspace(id: "code", name: "ws", agents: ["Fast", "Slow"]),
        AgentWorkspace(id: "general", name: "General", agents: ["Claude"]),
    ])

    var events: [AgentEvent] = []
    var result: (AgentStatus, String?)?
    client.run(AgentRequest(text: "ping", agent: "Fast"), onEvent: { events.append($0) }, onFinish: { result = ($0, $1) })
    await waitFor { result != nil }
    #expect(result?.0 == .completed)
    #expect(events.contains(.message("ดูโค้ดก่อน")))
    #expect(events.contains(.status(.testing)))
    #expect(events.contains(.completed("## Summary\npong")))

    // Cancelling finishes locally at once; the bridge's late reply is dropped by request id.
    var finished: [AgentStatus] = []
    client.run(AgentRequest(text: "wait", agent: "Slow"), onEvent: { _ in }, onFinish: { status, _ in finished.append(status) })
    try await Task.sleep(for: .milliseconds(300))
    client.cancel()
    try await Task.sleep(for: .milliseconds(300))
    #expect(finished == [.cancelled])

    // The bridge is free again after the cancel.
    result = nil
    client.run(AgentRequest(text: "again", agent: "Fast"), onEvent: { _ in }, onFinish: { result = ($0, $1) })
    await waitFor { result != nil }
    #expect(result?.0 == .completed)

    // Unknown agents fail cleanly.
    result = nil
    client.run(AgentRequest(text: "x", agent: "Nope"), onEvent: { _ in }, onFinish: { result = ($0, $1) })
    await waitFor { result != nil }
    #expect(result?.0 == .failed)
    client.disconnect()
}

/// The bridge dies and comes back (restart, crash, laptop sleep): the app reconnects by itself.
@MainActor @Test(.enabled(if: nodeAvailable))
func clientReconnectsWhenBridgeRestarts() async throws {
    let box = try Sandbox()
    let agents = try box.agents(#"[{"name":"Slow","cli":"claude","command":"\#(try box.script("slow", "sleep 30"))"}]"#)
    var bridge = try box.bridge(agents: agents)
    let port = bridge.port

    let client = BridgeClient()
    client.connect(pairingCode: bridge.pairingCode, host: "127.0.0.1", port: port)
    await waitFor { client.isConnected }
    #expect(client.isConnected)

    // A run in flight when the bridge dies fails instead of hanging forever.
    var result: AgentStatus?
    client.run(AgentRequest(text: "x", agent: "Slow"), onEvent: { _ in }, onFinish: { status, _ in result = status })
    try await Task.sleep(for: .milliseconds(200))
    bridge.stop()
    await waitFor { if case .waiting = client.state { true } else { false } }
    guard case .waiting = client.state else { Issue.record("expected .waiting after the bridge died, got \(client.state)"); return }
    await waitFor { result != nil }
    #expect(result == .failed)

    bridge = try box.bridge(port: port, agents: agents) // same home → same pairing code
    defer { bridge.stop() }
    await waitFor(seconds: 10) { client.isConnected }
    #expect(client.isConnected)
    client.disconnect()
}

/// A Mac app quitting (even crashing) closes the bridge's stdin; the bridge must not outlive it.
@Test(.enabled(if: nodeAvailable))
func localBridgeExitsWithItsOwner() async throws {
    let box = try Sandbox()
    let bridge = try box.bridge()
    var found: pid_t?
    for _ in 0..<50 where found == nil { // wait for it to bind (slower when the machine is busy)
        found = bridgePID(port: bridge.port)
        if found == nil { try await Task.sleep(for: .milliseconds(100)) }
    }
    let pid = try #require(found)
    bridge.stop()
    try await Task.sleep(for: .milliseconds(800))
    #expect(kill(pid, 0) != 0, "bridge process \(pid) still running")
}

private func bridgePID(port: UInt16) -> pid_t? {
    let lsof = Process()
    lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    lsof.arguments = ["-t", "-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
    let out = Pipe()
    lsof.standardOutput = out
    try? lsof.run()
    lsof.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").first.flatMap { pid_t($0) }
}

/// The bridge voices text with the Mac's neural voices (needs the Swift toolchain, as on any dev Mac).
@MainActor @Test(.enabled(if: nodeAvailable))
func bridgeSpeaksThai() async throws {
    let box = try Sandbox()
    let bridge = try box.bridge()
    defer { bridge.stop() }
    let client = BridgeClient()
    client.connect(pairingCode: bridge.pairingCode, host: "127.0.0.1", port: bridge.port)
    await waitFor { client.isConnected }
    #expect(client.canSpeak)

    let audio = try await client.synthesize("สวัสดีครับ แก้ไฟล์เรียบร้อยแล้ว")
    #expect(audio.count > 5000)
    #expect(String(decoding: audio[4..<8], as: UTF8.self) == "ftyp") // MPEG-4 audio
    client.disconnect()
}

/// App client → bridge → real CLI. Opt in with `VOXCODE_INTEGRATION=claude|codex swift test`.
@MainActor @Test(.enabled(if: nodeAvailable && ProcessInfo.processInfo.environment["VOXCODE_INTEGRATION"] != nil))
func bridgeRealAgent() async throws {
    let agent = ProcessInfo.processInfo.environment["VOXCODE_INTEGRATION"] == "codex" ? "Codex" : "Claude Code"
    let box = try Sandbox()
    let bridge = try box.bridge()
    defer { bridge.stop() }
    let client = BridgeClient()
    client.connect(pairingCode: bridge.pairingCode, host: "127.0.0.1", port: bridge.port)
    await waitFor { client.isConnected }

    var messages: [String] = []
    var result: AgentStatus?
    client.run(AgentRequest(text: "Reply with exactly: pong", agent: agent),
               onEvent: { if case .message(let t) = $0 { messages.append(t) } },
               onFinish: { status, _ in result = status })
    for _ in 0..<1200 where result == nil { try await Task.sleep(for: .milliseconds(100)) }
    #expect(result == .completed)
    #expect(messages.contains { $0.lowercased().contains("pong") })
}

/// Local-first with a saved address (the app's setting for Tailscale): whether Bonjour finds nothing or finds some
/// other bridge (wrong key), the client ends up on the saved address.
@MainActor @Test(.enabled(if: nodeAvailable))
func fallsBackToTheSavedAddress() async throws {
    let box = try Sandbox()
    let bridge = try box.bridge() // --managed: not advertised, reachable only at its address
    defer { bridge.stop() }
    let client = BridgeClient()
    client.connect(pairingCode: bridge.pairingCode, host: "127.0.0.1", port: bridge.port, preferLocalNetwork: true)
    await waitFor(seconds: 10) { client.isConnected }
    #expect(client.state == .connected(workspace: "ws"))
    client.disconnect()
}

@Test func pairingLinkRoundTrip() throws {
    let link = PairingLink(code: "ABCD-EFGH-JK23", host: "100.101.102.103")
    #expect(link.url.absoluteString == "voxagent://pair?code=ABCD-EFGH-JK23&host=100.101.102.103")
    #expect(PairingLink(url: link.url) == link)
    #expect(PairingLink(url: URL(string: "voxagent://pair?code=ABCD-EFGH-JK23&port=50000")!)?.port == 50000)
    #expect(PairingLink(url: URL(string: "voxagent://pair?code=SHORT")!) == nil)       // not a real code
    #expect(PairingLink(url: URL(string: "https://pair?code=ABCD-EFGH-JK23")!) == nil)  // wrong scheme
}

@Test func preferredHostPicksTailscaleFirst() {
    #expect(PairingLink.preferredHost(from: ["192.168.1.20", "100.88.1.2"]) == "100.88.1.2")
    #expect(PairingLink.preferredHost(from: ["192.168.1.20", "100.200.1.2"]) == "192.168.1.20") // 100.200 isn't Tailscale's range
    #expect(PairingLink.preferredHost(from: []) == nil)
}

@Test func servicePlistIsValidAndEscaped() throws {
    let xml = BridgeService.plist(node: "/n/node", script: "/a & b/bridge.mjs", workspace: "/w/<proj>", path: "/usr/bin", log: "/l.log")
    let plist = try #require(try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any])
    #expect(plist["ProgramArguments"] as? [String] == ["/usr/bin/caffeinate", "-i", "/n/node", "/a & b/bridge.mjs", "--workspace", "/w/<proj>"])
    #expect(plist["WorkingDirectory"] as? String == "/w/<proj>")
    #expect(plist["KeepAlive"] as? Bool == true)
}
