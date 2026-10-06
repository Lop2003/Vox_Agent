import CryptoKit
import Foundation
import Network
import Observation

// App ⇄ bridge (bridge/voxcode-bridge.mjs): newline-delimited JSON over TLS 1.2 with a pre-shared
// key derived from the pairing code the bridge prints, so the link is authenticated and encrypted
// without certificates. Bridges on the local network are found with Bonjour.
// The JSON is Swift's synthesized Codable form; keep the Node bridge in sync (see the wire test).

public enum VoxRemote {
    public static let serviceType = "_voxcode._tcp"
    public static let defaultPort: UInt16 = 47800
}

public enum ClientMessage: Codable, Equatable, Sendable {
    /// `language`: reply language; `mode`: `PermissionMode` raw value; `effort`: `Effort` raw value (nil = default).
    case run(id: UUID, text: String, agent: String, activeFile: String?, language: String?, mode: String?, effort: String?, model: String?, interrupted: String?)
    case cancel
    case reset
    /// Ask the bridge to voice `text` with the Mac's neural voices.
    case speak(id: UUID, text: String)
}

public enum ServerMessage: Codable, Equatable, Sendable {
    /// `speech` is nil from bridges that predate `speak`; `workspaces` from bridges without a General workspace.
    case hello(workspace: String, agents: [String], speech: Bool?, workspaces: [AgentWorkspace]?, models: [String: [AgentModel]]?)
    /// AAC audio for a `speak` request (base64 in JSON), or why there is none.
    case audio(id: UUID, data: Data?, error: String?)
    case event(id: UUID, event: AgentEvent)
    case finished(id: UUID, status: AgentStatus, error: String?)
}

public struct BridgeError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}

public enum PairingCode {
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // no 0/O/1/I

    /// 12 random symbols ≈ 60 bits, formatted XXXX-XXXX-XXXX.
    public static func generate() -> String {
        (0..<3).map { _ in String((0..<4).map { _ in alphabet.randomElement()! }) }.joined(separator: "-")
    }

    public static func normalize(_ code: String) -> String {
        code.uppercased().filter { alphabet.contains($0) }
    }
}

extension NWParameters {
    /// TLS-PSK parameters shared by the bridge and the app.
    public static func voxcode(pairingCode: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = SymmetricKey(data: Data(PairingCode.normalize(pairingCode).utf8))
        let psk = HMAC<SHA256>.authenticationCode(for: Data("VoxCode PSK".utf8), using: key)
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("VoxCode".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, pskData as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        return NWParameters(tls: tls, tcp: tcp)
    }
}

extension NWConnection {
    // JSONEncoder escapes newlines inside strings, so one message is exactly one line.
    func sendMessage<T: Encodable>(_ value: T) {
        guard var data = try? JSONEncoder().encode(value) else { return }
        data.append(0x0A)
        send(content: data, completion: .idempotent)
    }

    /// Calls `handler` on the main queue for every decoded message, then `onEnd` once the stream ends.
    func receiveMessages<T: Decodable>(_ type: T.Type, buffer: LineBuffer = LineBuffer(),
                                       handler: @escaping @MainActor (T) -> Void,
                                       onEnd: @escaping @MainActor (NWError?) -> Void = { _ in }) {
        receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            for line in data.map(buffer.append) ?? [] {
                if let message = try? JSONDecoder().decode(T.self, from: Data(line.utf8)) {
                    MainActor.assumeIsolated { handler(message) }
                }
            }
            if error == nil, !isComplete, let self {
                self.receiveMessages(T.self, buffer: buffer, handler: handler, onEnd: onEnd)
            } else {
                MainActor.assumeIsolated { onEnd(error) }
            }
        }
    }
}


/// Phone side: finds the Mac bridge (Bonjour or explicit host) and forwards runs to it.
@MainActor @Observable
public final class BridgeClient: AgentRunner {
    public enum State: Equatable {
        case disconnected
        case searching
        case connecting
        case connected(workspace: String)
        /// Lost or couldn't reach the bridge; retrying on its own.
        case waiting(String)
        /// Needs the user, e.g. a wrong pairing code. No automatic retry.
        case failed(String)
    }

    public private(set) var state = State.disconnected
    public private(set) var macName: String?
    public private(set) var agents: [String] = []
    public private(set) var workspaces: [AgentWorkspace] = []
    public private(set) var models: [String: [AgentModel]] = [:]
    /// The bridge can voice text with the Mac's (much more natural) neural voices.
    public private(set) var canSpeak = false
    private var speechRequests: [UUID: CheckedContinuation<Data, Error>] = [:]

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var target: (code: String, host: String?, port: UInt16, preferLocal: Bool)?
    /// The saved address to fall back to when the bridge isn't on this network (e.g. a Tailscale IP).
    private var savedEndpoint: (endpoint: NWEndpoint, parameters: NWParameters)?
    private var fallbackTask: Task<Void, Never>?
    private var usingSavedEndpoint = false
    private var retryTask: Task<Void, Never>?
    private var attempts = 0
    private var pending: (id: UUID, onEvent: @MainActor (AgentEvent) -> Void, onFinish: @MainActor (AgentStatus, String?) -> Void)?

    public init() {}

    public var isConnected: Bool {
        if case .connected = state { true } else { false }
    }

    /// Connects to `host` if given, otherwise to the first bridge Bonjour finds on the local network.
    /// Keeps reconnecting (1 s, 2 s … up to 5 s apart) if the bridge goes away, until `disconnect()` or a wrong code.
    /// - Parameter preferLocalNetwork: with a saved `host`, look for the bridge on this Wi-Fi first (Bonjour) and
    ///   use `host` only if it isn't found within 1.5 s — so one setting works at home and away (Tailscale).
    public func connect(pairingCode: String, host: String? = nil, port: UInt16 = VoxRemote.defaultPort, preferLocalNetwork: Bool = false) {
        target = (pairingCode, host, port, preferLocalNetwork)
        attempts = 0
        start()
    }

    private func start() {
        guard let (pairingCode, host, port, preferLocal) = target else { return }
        teardown()
        let parameters = NWParameters.voxcode(pairingCode: pairingCode)
        usingSavedEndpoint = false
        savedEndpoint = nil
        if let host, !host.isEmpty {
            savedEndpoint = (.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!), parameters)
            if !preferLocal { return useSavedEndpoint() }
            fallbackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled, self.connection == nil else { return }
                self.useSavedEndpoint()
            }
        }
        state = .searching
        // ponytail: connects to the first Mac found; add a picker if people run several bridges.
        let browser = NWBrowser(for: .bonjour(type: VoxRemote.serviceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.connection == nil, let result = results.first else { return }
                if case .service(let name, _, _, _) = result.endpoint { self.macName = name }
                self.browser?.cancel()
                self.browser = nil
                self.open(result.endpoint, parameters)
                // A rejected Bonjour endpoint can keep retrying its other addresses instead of failing,
                // so if it isn't talking to us within 3 s, use the saved address.
                if self.savedEndpoint != nil {
                    self.fallbackTask?.cancel()
                    self.fallbackTask = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(3))
                        guard let self, !Task.isCancelled, !self.isConnected, !self.usingSavedEndpoint else { return }
                        self.useSavedEndpoint()
                    }
                }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Can't search this network: go straight to the saved address if there is one.
                if case .failed = state, self.savedEndpoint != nil { return self.useSavedEndpoint() }
                if case .waiting = state, self.savedEndpoint != nil { return self.useSavedEndpoint() }
                if case .failed(let error) = state { self.fail("Can't search the local network: \(error.localizedDescription)", retry: true) }
                if case .waiting(let error) = state { self.fail("Local network access is off or unavailable: \(error.localizedDescription). Allow it in Settings › Privacy & Security › Local Network.", retry: false) }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    public func disconnect() {
        target = nil
        teardown()
        finishPending(.failed, "Disconnected from the agent bridge.")
        state = .disconnected
    }

    private func useSavedEndpoint() {
        guard let (endpoint, parameters) = savedEndpoint else { return }
        fallbackTask?.cancel()
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        usingSavedEndpoint = true
        if case .hostPort(let host, _) = endpoint { macName = "\(host)" }
        open(endpoint, parameters)
    }

    private func teardown() {
        fallbackTask?.cancel()
        fallbackTask = nil
        for request in speechRequests.values { request.resume(throwing: BridgeError("Disconnected from the agent bridge.")) }
        speechRequests = [:]
        retryTask?.cancel()
        retryTask = nil
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
    }

    /// A TLS failure means the bridge rejected our key: retrying with the same code can't help.
    private static func isAuthFailure(_ error: NWError?) -> Bool {
        if case .tls = error { true } else { false }
    }

    private func lost(_ error: NWError?) {
        // A bridge found on this Wi-Fi that isn't ours (wrong key) or that went away: try the saved address.
        if savedEndpoint != nil, !usingSavedEndpoint, connection != nil { return useSavedEndpoint() }
        if Self.isAuthFailure(error) {
            fail("The bridge rejected the pairing code. Check the code and pair again.", retry: false)
        } else {
            fail("Can't reach the bridge — retrying…" + (error.map { " (\($0.localizedDescription))" } ?? ""), retry: true)
        }
    }

    private func open(_ endpoint: NWEndpoint, _ parameters: NWParameters) {
        state = .connecting
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection, connection === self.connection else { return }
                switch state {
                case .failed(let error), .waiting(let error): self.lost(error)
                default: break // .ready is confirmed by the server's hello
                }
            }
        }
        connection.receiveMessages(ServerMessage.self, handler: { [weak self] message in self?.handle(message) },
                                   onEnd: { [weak self, weak connection] error in
                                       // The bridge closed or restarted while we were connected.
                                       guard let self, let connection, connection === self.connection else { return }
                                       self.lost(error)
                                   })
        self.connection = connection
        connection.start(queue: .main)
    }

    private func fail(_ message: String, retry: Bool) {
        teardown()
        finishPending(.failed, "Lost connection to the bridge.")
        guard retry, target != nil else { return state = .failed(message) }
        state = .waiting(message)
        attempts += 1
        let delay = Double(min(attempts, 5))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if !Task.isCancelled { self?.start() }
        }
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .hello(let workspace, let agents, let speech, let workspaces, let models):
            self.models = models ?? [:]
            attempts = 0
            self.agents = agents
            self.workspaces = workspaces ?? [AgentWorkspace(id: AgentWorkspace.code, name: workspace, agents: agents)]
            canSpeak = speech ?? false
            state = .connected(workspace: workspace)
        // Replies for a request that was already cancelled locally are dropped.
        case .event(let id, let event) where id == pending?.id: pending?.onEvent(event)
        case .finished(let id, let status, let error) where id == pending?.id: finishPending(status, error)
        case .event, .finished: break
        case .audio(let id, let data, let error):
            resolveSpeech(id, data.map { .success($0) } ?? .failure(BridgeError(error ?? "The bridge sent no audio.")))
        }
    }

    /// AAC audio of `text` spoken by the bridge's Mac voices.
    public func synthesize(_ text: String) async throws -> Data {
        guard isConnected, canSpeak, let connection else { throw BridgeError("Bridge speech is not available.") }
        let id = UUID()
        connection.sendMessage(ClientMessage.speak(id: id, text: text))
        return try await withCheckedThrowingContinuation { continuation in
            speechRequests[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.resolveSpeech(id, .failure(BridgeError("The bridge took too long to speak.")))
            }
        }
    }

    private func resolveSpeech(_ id: UUID, _ result: Result<Data, Error>) {
        speechRequests.removeValue(forKey: id)?.resume(with: result)
    }

    private func finishPending(_ status: AgentStatus, _ error: String?) {
        let pending = pending
        self.pending = nil
        pending?.onFinish(status, error)
    }

    // MARK: AgentRunner

    public func run(_ request: AgentRequest,
                    onEvent: @escaping @MainActor (AgentEvent) -> Void,
                    onFinish: @escaping @MainActor (AgentStatus, String?) -> Void) {
        guard isConnected, let connection else { return onFinish(.failed, "Not connected to the agent bridge yet.") }
        let id = UUID()
        pending = (id, onEvent, onFinish)
        connection.sendMessage(ClientMessage.run(id: id, text: request.text, agent: request.agent, activeFile: request.activeFile,
                                                 language: request.language, mode: request.mode.rawValue,
                                                 effort: request.effort == .standard ? nil : request.effort.rawValue,
                                                 model: request.model, interrupted: request.interrupted))
    }

    public func cancel() {
        guard pending != nil else { return }
        connection?.sendMessage(ClientMessage.cancel)
        finishPending(.cancelled, nil) // don't wait for the round trip; the late reply is dropped by id
    }

    public func reset() {
        finishPending(.cancelled, nil)
        connection?.sendMessage(ClientMessage.reset)
    }
}

/// Splits raw bytes into lines (on '\n', so UTF-8 sequences are never cut) and keeps a stderr tail.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private var stderr = Data()

    func append(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let i = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[pending.startIndex..<i], as: UTF8.self)
            pending.removeSubrange(pending.startIndex...i)
            if !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    func flush() -> String? {
        lock.lock(); defer { lock.unlock() }
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return line.isEmpty ? nil : line
    }

    func appendError(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        stderr.append(data)
        if stderr.count > 4000 { stderr = stderr.suffix(4000) }
    }

    var errorTail: String {
        lock.lock(); defer { lock.unlock() }
        let lines = String(decoding: stderr, as: UTF8.self).split(separator: "\n").suffix(3)
        return lines.joined(separator: "\n")
    }
}
