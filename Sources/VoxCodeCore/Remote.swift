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
    case run(id: UUID, text: String, agent: String, activeFile: String?)
    case cancel
    case reset
}

public enum ServerMessage: Codable, Equatable, Sendable {
    case hello(workspace: String, agents: [String])
    case event(id: UUID, event: AgentEvent)
    case finished(id: UUID, status: AgentStatus, error: String?)
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

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var target: (code: String, host: String?, port: UInt16)?
    private var retryTask: Task<Void, Never>?
    private var attempts = 0
    private var pending: (id: UUID, onEvent: @MainActor (AgentEvent) -> Void, onFinish: @MainActor (AgentStatus, String?) -> Void)?

    public init() {}

    public var isConnected: Bool {
        if case .connected = state { true } else { false }
    }

    /// Connects to `host` if given, otherwise to the first bridge Bonjour finds on the local network.
    /// Keeps reconnecting (1 s, 2 s … up to 5 s apart) if the bridge goes away, until `disconnect()` or a wrong code.
    public func connect(pairingCode: String, host: String? = nil, port: UInt16 = VoxRemote.defaultPort) {
        target = (pairingCode, host, port)
        attempts = 0
        start()
    }

    private func start() {
        guard let (pairingCode, host, port) = target else { return }
        teardown()
        let parameters = NWParameters.voxcode(pairingCode: pairingCode)
        if let host, !host.isEmpty {
            macName = host
            open(.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!), parameters)
            return
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
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed(let error) = state { self?.fail("Can't search the local network: \(error.localizedDescription)", retry: true) }
                if case .waiting(let error) = state { self?.fail("Local network access is off or unavailable: \(error.localizedDescription). Allow it in Settings › Privacy & Security › Local Network.", retry: false) }
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

    private func teardown() {
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
        case .hello(let workspace, let agents):
            attempts = 0
            self.agents = agents
            state = .connected(workspace: workspace)
        // Replies for a request that was already cancelled locally are dropped.
        case .event(let id, let event) where id == pending?.id: pending?.onEvent(event)
        case .finished(let id, let status, let error) where id == pending?.id: finishPending(status, error)
        case .event, .finished: break
        }
    }

    private func finishPending(_ status: AgentStatus, _ error: String?) {
        let pending = pending
        self.pending = nil
        pending?.onFinish(status, error)
    }

    // MARK: AgentRunner

    public func run(_ text: String, agent: String, activeFile: String?,
                    onEvent: @escaping @MainActor (AgentEvent) -> Void,
                    onFinish: @escaping @MainActor (AgentStatus, String?) -> Void) {
        guard isConnected, let connection else { return onFinish(.failed, "Not connected to the agent bridge yet.") }
        let id = UUID()
        pending = (id, onEvent, onFinish)
        connection.sendMessage(ClientMessage.run(id: id, text: text, agent: agent, activeFile: activeFile))
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
