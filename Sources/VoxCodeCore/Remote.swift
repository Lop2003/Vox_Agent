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

    /// Calls `handler` on the main queue for every decoded message until the connection ends.
    func receiveMessages<T: Decodable>(_ type: T.Type, buffer: LineBuffer = LineBuffer(), handler: @escaping @MainActor (T) -> Void) {
        receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            for line in data.map(buffer.append) ?? [] {
                if let message = try? JSONDecoder().decode(T.self, from: Data(line.utf8)) {
                    MainActor.assumeIsolated { handler(message) }
                }
            }
            if error == nil, !isComplete { self?.receiveMessages(T.self, buffer: buffer, handler: handler) }
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
        case failed(String)
    }

    public private(set) var state = State.disconnected
    public private(set) var macName: String?
    public private(set) var agents: [String] = []

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var pending: (id: UUID, onEvent: @MainActor (AgentEvent) -> Void, onFinish: @MainActor (AgentStatus, String?) -> Void)?

    public init() {}

    public var isConnected: Bool {
        if case .connected = state { true } else { false }
    }

    /// Connects to `host` if given, otherwise to the first bridge Bonjour finds on the local network.
    public func connect(pairingCode: String, host: String? = nil, port: UInt16 = VoxRemote.defaultPort) {
        disconnect()
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
                if case .failed(let error) = state { self?.fail("Can't search the local network: \(error.localizedDescription)") }
                if case .waiting(let error) = state { self?.fail("Local network access is off or unavailable: \(error.localizedDescription). Allow it in Settings › Privacy & Security › Local Network.") }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    public func disconnect() {
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        finishPending(.failed, "Disconnected from your Mac.")
        state = .disconnected
    }

    private func open(_ endpoint: NWEndpoint, _ parameters: NWParameters) {
        state = .connecting
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection, connection === self.connection else { return }
                switch state {
                case .failed(let error), .waiting(let error):
                    self.fail("Couldn't reach the Mac bridge. Check the pairing code and that `voxcode-bridge` is running. (\(error.localizedDescription))")
                default:
                    break // .ready is confirmed by the server's hello
                }
            }
        }
        connection.receiveMessages(ServerMessage.self) { [weak self] message in self?.handle(message) }
        self.connection = connection
        connection.start(queue: .main)
    }

    private func fail(_ message: String) {
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        finishPending(.failed, "Lost connection to your Mac.")
        state = .failed(message)
    }

    private func handle(_ message: ServerMessage) {
        switch message {
        case .hello(let workspace, let agents):
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
        guard isConnected, let connection else { return onFinish(.failed, "Not connected to your Mac.") }
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
