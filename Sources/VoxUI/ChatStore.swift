import Foundation
import VoxCodeCore

/// A saved chat: its turns and when it was last touched. The title is the first thing the user asked.
public struct Conversation: Identifiable, Codable, Equatable {
    public var id: UUID
    public var turns: [Turn]
    public var updatedAt: Date
    /// `AgentWorkspace.id` the chat belongs to; nil for chats saved before workspaces (the project workspace).
    public var workspace: String?

    public var title: String { turns.first?.user ?? "New conversation" }
}

/// Chat history on this device: one JSON file in Application Support (never leaves the device).
public struct ChatStore {
    let url: URL

    public init(url: URL) { self.url = url }

    public static let standard = ChatStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Vox Agent/conversations.json"))

    /// Newest first. A turn still running when the app quit is shown as cancelled.
    public func load() -> [Conversation] {
        guard let data = try? Data(contentsOf: url),
              var conversations = try? JSONDecoder.iso.decode([Conversation].self, from: data) else { return [] }
        for c in conversations.indices {
            for t in conversations[c].turns.indices where [.analyzing, .editing, .testing].contains(conversations[c].turns[t].status) {
                conversations[c].turns[t].status = .cancelled
            }
        }
        return conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    // ponytail: rewrites one file per save; fine for hundreds of chats, split per conversation if it grows.
    public func save(_ conversations: [Conversation]) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder.iso.encode(conversations).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            print("Vox Agent: couldn't save chat history: \(error)")
        }
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

private extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}
