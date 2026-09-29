import Foundation

#if os(macOS)

public enum AgentError: LocalizedError, Equatable {
    case notInstalled(String)
    case processFailed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let name):
            "`\(name)` CLI not found. Install it and make sure it is on your PATH."
        case .processFailed(let code, let stderr):
            "Agent exited with code \(code)" + (stderr.isEmpty ? "." : ": \(stderr)")
        }
    }
}

/// Runs a CLI and streams its stdout line by line. Cancelling the stream terminates the process.
enum ProcessLines {
    // GUI apps get a minimal PATH; add the usual install locations for claude/codex (and node).
    static let extraPaths = ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.npm-global/bin", "~/.bun/bin"]
        .map { NSString(string: $0).expandingTildeInPath }

    static func run(_ executable: String, _ arguments: [String], cwd: URL) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
            process.currentDirectoryURL = cwd
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = ([env["PATH"] ?? "/usr/bin:/bin"] + extraPaths).joined(separator: ":")
            process.environment = env
            process.standardInput = FileHandle.nullDevice

            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let buffer = LineBuffer()

            out.fileHandleForReading.readabilityHandler = { handle in
                for line in buffer.append(handle.availableData) { continuation.yield(line) }
            }
            err.fileHandleForReading.readabilityHandler = { handle in
                buffer.appendError(handle.availableData)
            }
            process.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                for line in buffer.append(out.fileHandleForReading.readDataToEndOfFile()) { continuation.yield(line) }
                if let rest = buffer.flush() { continuation.yield(rest) }
                switch p.terminationStatus {
                case 0: continuation.finish()
                case 127: continuation.finish(throwing: AgentError.notInstalled(executable))
                default: continuation.finish(throwing: AgentError.processFailed(p.terminationStatus, buffer.errorTail))
                }
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
#endif

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
