#if os(macOS)
import Foundation

/// Runs bridge/voxcode-bridge.mjs as a child process for one workspace, listening on localhost only.
/// The Mac app talks to it through `BridgeClient`, so Mac and iPhone share one agent implementation.
public final class LocalBridge {
    public let workspace: URL
    public let port: UInt16
    public let pairingCode: String
    /// Called on the main queue if the bridge exits on its own (e.g. Node.js missing: status 127).
    public var onExit: ((Int32) -> Void)?

    private let process = Process()
    private let stdin = Pipe() // --managed: the bridge exits when this closes, even if we crash

    // GUI apps get a minimal PATH; add the usual install locations for node, claude, codex and ollama.
    static let extraPaths = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.npm-global/bin", "~/.bun/bin"]
        .map { NSString(string: $0).expandingTildeInPath }

    /// - Parameters:
    ///   - home: private folder for the bridge's pairing code and log (created with mode 0700).
    ///   - port: fixed port (to reconnect to a restarted bridge), or nil for any free one.
    public init(script: URL, workspace: URL, home: URL, port: UInt16? = nil, agentsFile: URL? = nil) throws {
        self.workspace = workspace
        self.port = port ?? Self.freePort()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let codeFile = home.appendingPathComponent("pairing-code")
        if let saved = try? String(contentsOf: codeFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            pairingCode = saved
        } else {
            pairingCode = PairingCode.generate()
            FileManager.default.createFile(atPath: codeFile.path, contents: Data(pairingCode.utf8), attributes: [.posixPermissions: 0o600])
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path, "--workspace", workspace.path, "--port", String(self.port),
                             "--host", "127.0.0.1", "--managed"] + (agentsFile.map { ["--agents", $0.path] } ?? [])
        var env = ProcessInfo.processInfo.environment
        env["VOXCODE_HOME"] = home.path
        env["PATH"] = ([env["PATH"] ?? "/usr/bin:/bin"] + Self.extraPaths).joined(separator: ":")
        process.environment = env
        process.standardInput = stdin
        let logURL = home.appendingPathComponent("bridge.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        process.standardOutput = log
        process.standardError = log
        process.terminationHandler = { [weak self] p in
            DispatchQueue.main.async { self?.onExit?(p.terminationStatus) }
        }
        try process.run()
    }

    public func stop() {
        onExit = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }

    /// The bridge script shipped in the app bundle (see scripts/build-app.sh).
    public static var bundledScript: URL? {
        Bundle.main.url(forResource: "voxcode-bridge", withExtension: "mjs")
    }

    /// Asks the OS for an unused localhost port.
    static func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = bind(fd, $0, length)
                _ = getsockname(fd, $0, &length)
            }
        }
        return UInt16(bigEndian: addr.sin_port)
    }
}
#endif
