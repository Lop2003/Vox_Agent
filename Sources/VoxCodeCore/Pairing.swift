import Foundation

/// `voxagent://pair?code=…&host=…&port=…`: shown as a QR code by the Mac app; scanning it with the iPhone Camera
/// opens the app and pairs, with no typing.
public struct PairingLink: Equatable, Sendable {
    public var code: String
    /// Address to use when the bridge isn't found on the local Wi-Fi (a Tailscale IP works everywhere).
    public var host: String?
    public var port: UInt16

    public init(code: String, host: String?, port: UInt16 = VoxRemote.defaultPort) {
        self.code = code
        self.host = host
        self.port = port
    }

    public var url: URL {
        var c = URLComponents()
        c.scheme = "voxagent"
        c.host = "pair"
        c.queryItems = [URLQueryItem(name: "code", value: code)]
            + (host.map { [URLQueryItem(name: "host", value: $0)] } ?? [])
            + (port == VoxRemote.defaultPort ? [] : [URLQueryItem(name: "port", value: String(port))])
        return c.url!
    }

    public init?(url: URL) {
        guard url.scheme == "voxagent", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value,
              PairingCode.normalize(code).count == 12 else { return nil }
        self.code = code
        host = items.first { $0.name == "host" }?.value.flatMap { $0.isEmpty ? nil : $0 }
        port = items.first { $0.name == "port" }?.value.flatMap(UInt16.init) ?? VoxRemote.defaultPort
    }

    /// Tailscale (100.64.0.0/10) first: it reaches the Mac from any network. Otherwise the first LAN address.
    public static func preferredHost(from addresses: [String]) -> String? {
        func isTailscale(_ ip: String) -> Bool {
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
        }
        return addresses.first(where: isTailscale) ?? addresses.first
    }
}

#if os(macOS)
import Darwin

/// The bridge as a login service (launchd), managed from the Mac app. Same label and files as
/// scripts/bridge-service.sh, so either can install or remove it.
public enum BridgeService {
    public static let label = "com.voxagent.bridge"
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".voxcode")
    static let plistURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    static let codeURL = home.appendingPathComponent("pairing-code")
    static var domain: String { "gui/\(getuid())" }

    /// launchd plist: runs the bridge under `caffeinate -i` (no idle sleep), restarts it if it dies.
    public static func plist(node: String, script: String, workspace: String, path: String, log: String) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/caffeinate</string>
                <string>-i</string>
                <string>\(esc(node))</string>
                <string>\(esc(script))</string>
                <string>--workspace</string>
                <string>\(esc(workspace))</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict><key>PATH</key><string>\(esc(path))</string></dict>
            <key>WorkingDirectory</key><string>\(esc(workspace))</string>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ThrottleInterval</key><integer>5</integer>
            <key>StandardOutPath</key><string>\(esc(log))</string>
            <key>StandardErrorPath</key><string>\(esc(log))</string>
        </dict>
        </plist>
        """
    }

    public static var isRunning: Bool {
        run("/bin/launchctl", ["print", "\(domain)/\(label)"]).output.contains("state = running")
    }

    /// The workspace the installed service serves, if any.
    public static var workspace: URL? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let dir = plist["WorkingDirectory"] as? String else { return nil }
        return URL(fileURLWithPath: dir)
    }

    /// The pairing code, created (private to this user) if there isn't one yet.
    public static func pairingCode(renew: Bool = false) throws -> String {
        if !renew, let saved = try? String(contentsOf: codeURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return saved
        }
        let code = PairingCode.generate()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: codeURL.path, contents: Data(code.utf8), attributes: [.posixPermissions: 0o600])
        return code
    }

    /// Installs (or moves to a new folder) and starts the service. `script` is the bridge .mjs to run.
    public static func install(workspace: URL, script: URL) throws {
        guard let node = nodePath() else { throw BridgeError("Node.js not found. Install it (brew install node) and try again.") }
        _ = try pairingCode()
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let log = home.appendingPathComponent("bridge.log").path
        try plist(node: node, script: script.path, workspace: workspace.path, path: userPATH, log: log)
            .write(to: plistURL, atomically: true, encoding: .utf8)
        restart()
    }

    public static func restart() {
        run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        // bootout returns before the old instance is gone; bootstrapping too early fails.
        for _ in 0..<10 where run("/bin/launchctl", ["print", "\(domain)/\(label)"]).status == 0 { usleep(500_000) }
        run("/bin/launchctl", ["bootstrap", domain, plistURL.path])
    }

    public static func stop() {
        run("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// IPv4 addresses of this Mac's network interfaces (Wi-Fi, Ethernet, Tailscale), loopback excluded.
    public static func addresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var cursor = list
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("169.254."), !result.contains(ip) { result.append(ip) } // skip link-local
            }
        }
        return result
    }

    /// The PATH a Terminal would have (so the service finds claude / codex / ollama), plus common install dirs.
    static var userPATH: String {
        let shell = run("/bin/zsh", ["-lic", "echo -n $PATH"]).output.split(separator: "\n").last.map(String.init) ?? ""
        let extra = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.npm-global/bin", "~/.bun/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .map { NSString(string: $0).expandingTildeInPath }
        var seen = Set<String>()
        return (shell.split(separator: ":").map(String.init) + extra).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    static func nodePath() -> String? {
        userPATH.split(separator: ":").map { "\($0)/node" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return (-1, "") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
#endif
