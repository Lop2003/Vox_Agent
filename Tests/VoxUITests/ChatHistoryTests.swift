import Foundation
import Testing
import VoxCodeCore
@testable import VoxUI

/// Answers every request immediately, like a very fast agent.
@MainActor
private final class FakeRunner: AgentRunner {
    var agents = ["Fake"]
    lazy var workspaces = [AgentWorkspace(id: AgentWorkspace.code, name: "Workspace", agents: agents)]
    var resets = 0
    func run(_ request: AgentRequest,
             onEvent: @escaping @MainActor (AgentEvent) -> Void,
             onFinish: @escaping @MainActor (AgentStatus, String?) -> Void) {
        let text = request.text
        onEvent(.message("## Summary\nanswer to \(text)"))
        onFinish(.completed, nil)
    }
    func cancel() {}
    func reset() { resets += 1 }
}

@MainActor
struct ChatHistoryTests {
    private let store = ChatStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("vox-\(UUID()).json"))

    private func model() -> (AppModel, FakeRunner) {
        let model = AppModel(store: store)
        let runner = FakeRunner()
        model.runner = runner
        return (model, runner)
    }

    private func ask(_ model: AppModel, _ text: String) {
        model.transcript = text
        model.send()
    }

    @Test func chatsAreSavedAndSurviveRelaunch() {
        let (first, _) = model()
        ask(first, "hello")
        ask(first, "again")
        first.newConversation()
        ask(first, "second chat")

        let relaunched = AppModel(store: store) // a fresh app launch reads the same file
        #expect(relaunched.conversations.map(\.title) == ["second chat", "hello"]) // newest first
        #expect(relaunched.conversations.last?.turns.map(\.user) == ["hello", "again"])
        #expect(relaunched.conversations.last?.turns.first?.response == "## Summary\nanswer to hello")
        #expect(relaunched.turns.isEmpty) // starts on a new chat
    }

    @Test func workspacesHaveTheirOwnAgentsAndChats() {
        let (model, runner) = model()
        runner.workspaces = [
            AgentWorkspace(id: AgentWorkspace.code, name: "app", agents: ["Fake"]),
            AgentWorkspace(id: AgentWorkspace.general, name: "General", agents: ["Chat"]),
        ]
        defer { model.workspaceID = AgentWorkspace.code }
        model.workspaceID = AgentWorkspace.code
        ask(model, "fix the build")

        model.workspaceID = AgentWorkspace.general
        #expect(model.turns.isEmpty) // switching starts a new chat
        #expect(model.agent == "Chat")
        #expect(model.workspaceConversations.isEmpty)
        ask(model, "plan a trip")
        #expect(model.turns.last?.agent == "Chat")
        #expect(model.workspaceConversations.map(\.title) == ["plan a trip"])

        model.workspaceID = AgentWorkspace.code
        #expect(model.agent == "Fake")
        #expect(model.workspaceConversations.map(\.title) == ["fix the build"])
        #expect(AppModel(store: store).conversations.count == 2) // both saved, each tagged with its workspace
    }

    @Test func openingAChatShowsItsTurnsAndResetsTheAgent() {
        let (model, runner) = model()
        ask(model, "old question")
        let old = model.conversationID
        model.newConversation()
        ask(model, "new question")

        model.open(model.conversations.first { $0.id == old }!)
        #expect(model.conversationID == old)
        #expect(model.turns.map(\.user) == ["old question"])
        #expect(runner.resets == 2) // new conversation + open: the agent never mixes two chats' context

        ask(model, "follow-up") // continuing an old chat keeps saving into it
        #expect(AppModel(store: store).conversations.first?.turns.map(\.user) == ["old question", "follow-up"])
    }

    @Test func deletingTheOpenChatStartsANewOne() {
        let (model, _) = model()
        ask(model, "to delete")
        let open = model.conversations[0]
        model.delete(open)
        #expect(model.conversations.isEmpty)
        #expect(model.turns.isEmpty)
        #expect(model.conversationID != open.id)
        #expect(AppModel(store: store).conversations.isEmpty)
    }

    @Test func aTurnStillRunningAtQuitLoadsAsCancelled() throws {
        var turn = Turn(user: "long job", agent: "Fake")
        turn.status = .editing
        store.save([Conversation(id: UUID(), turns: [turn], updatedAt: Date())])
        #expect(store.load().first?.turns.first?.status == .cancelled)
    }
}

/// Streams an answer the way a local model does: the same message growing, then done.
@MainActor
private final class StreamingRunner: AgentRunner {
    var agents = ["Local"]
    let pieces: [String]
    init(_ pieces: [String]) { self.pieces = pieces }
    func run(_ request: AgentRequest,
             onEvent: @escaping @MainActor (AgentEvent) -> Void,
             onFinish: @escaping @MainActor (AgentStatus, String?) -> Void) {
        let text = request.text
        var answer = ""
        for piece in pieces {
            answer += piece
            onEvent(.message(answer))
        }
        onEvent(.completed(answer))
        onFinish(.completed, nil)
    }
    func cancel() {}
    func reset() {}
}

@MainActor
struct StreamingSpeechTests {
    @Test func speaksEachSentenceAsItArrivesAndOnlyOnce() {
        let model = AppModel(store: ChatStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("vox-\(UUID()).json")))
        model.tts.volume = 0
        model.autoSpeak = true
        defer { model.autoSpeak = false; model.cancel() }
        model.runner = StreamingRunner(["## Sum", "mary\n", "สวัสดีครับ. ", "วันนี้ให้ช่วย", "อะไรดี"])
        model.transcript = "hi"
        model.send()
        #expect(model.spokenLog == ["สวัสดีครับ.", "วันนี้ให้ช่วยอะไรดี"]) // no "Summary", no repeats
        #expect(model.turns.last?.response == "## Summary\nสวัสดีครับ. วันนี้ให้ช่วยอะไรดี")
    }

    @Test func wholeMessagesAreSpokenAtTheEndAsBefore() {
        let model = AppModel(store: ChatStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("vox-\(UUID()).json")))
        model.tts.volume = 0
        model.autoSpeak = true
        defer { model.autoSpeak = false; model.cancel() }
        model.runner = FakeRunner() // one complete message (Claude Code style)
        model.transcript = "hello"
        model.send()
        #expect(model.spokenLog == ["answer to hello"])
    }
}

@MainActor
struct MuteTests {
    @Test func muteTogglesAndHangingUpUnmutes() {
        let model = AppModel(store: ChatStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("vox-\(UUID()).json")))
        model.toggleMute()
        #expect(model.micMuted)
        model.toggleMute()
        #expect(!model.micMuted)
        model.toggleMute()
        model.cancel() // ending the call resets mute for the next one
        #expect(!model.micMuted)
    }
}

/// Counts how many requests actually reached the agent.
@MainActor
final class CountingRunner: AgentRunner {
    var agents = ["Claude Code"]
    var runs: [String] = []
    func run(_ request: AgentRequest,
             onEvent: @escaping @MainActor (AgentEvent) -> Void,
             onFinish: @escaping @MainActor (AgentStatus, String?) -> Void) {
        let text = request.text
        runs.append(text)
        onFinish(.completed, nil)
    }
    func cancel() {}
    func reset() {}
}

@MainActor
struct ConfirmChangesTests {
    private func model() -> (AppModel, CountingRunner) {
        let model = AppModel(store: ChatStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("vox-\(UUID()).json")))
        model.tts.volume = 0
        model.permissionMode = .auto
        let runner = CountingRunner()
        model.runner = runner
        return (model, runner)
    }

    @Test func spokenChangeWaitsForYes() {
        let (model, runner) = model()
        model.transcript = "สร้างไฟล์ markdown สรุปโปรเจกต์"
        model.send(spoken: true)
        #expect(runner.runs.isEmpty)
        #expect(model.pendingRequest == "สร้างไฟล์ markdown สรุปโปรเจกต์")

        model.transcript = "ใช่"          // the spoken answer
        model.send(spoken: true)
        #expect(runner.runs == ["สร้างไฟล์ markdown สรุปโปรเจกต์"])
        #expect(model.pendingRequest == nil)
    }

    @Test func noCancelsAndANewRequestReplaces() {
        let (model, runner) = model()
        model.transcript = "ลบไฟล์ test ทั้งหมด"
        model.send(spoken: true)
        model.transcript = "ไม่"
        model.send(spoken: true)
        #expect(runner.runs.isEmpty)
        #expect(model.pendingRequest == nil)

        model.transcript = "แก้ไฟล์ README"
        model.send(spoken: true)
        model.transcript = "อธิบายโปรเจกต์ให้ฟังแทน" // not yes/no: a new request, which needs no confirmation
        model.send(spoken: true)
        #expect(runner.runs == ["อธิบายโปรเจกต์ให้ฟังแทน"])
    }

    @Test func typedOrHarmlessRequestsGoStraightThrough() {
        let (model, runner) = model()
        model.transcript = "แก้ไฟล์ README"
        model.send()                         // typed/reviewed: the user already saw the text
        model.transcript = "โปรเจกต์นี้ทำอะไรได้บ้าง"
        model.send(spoken: true)             // spoken but read-only
        #expect(runner.runs == ["แก้ไฟล์ README", "โปรเจกต์นี้ทำอะไรได้บ้าง"])
    }
}

@MainActor
struct ConfirmWhileListeningTests {
    /// In a call the app asks "ใช่ไหม" and listens; tapping Run must still send (it used to do nothing).
    @Test func tappingRunWhileListeningSends() {
        let model = AppModel(store: ChatStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("vox-\(UUID()).json")))
        model.tts.volume = 0
        model.permissionMode = .auto
        let runner = CountingRunner()
        model.runner = runner
        model.transcript = "สร้างไฟล์ README"
        model.send(spoken: true)
        model.phase = .listening // the mic opened for the spoken answer
        model.transcript = "อ"   // a partial word already heard
        model.confirmPending()
        #expect(runner.runs == ["สร้างไฟล์ README"])
    }
}

/// Starts answering and keeps going until cancelled; records every request.
@MainActor
final class HangingRunner: AgentRunner {
    var agents = ["Claude"]
    var requests: [AgentRequest] = []
    private var finish: (@MainActor (AgentStatus, String?) -> Void)?
    func run(_ request: AgentRequest,
             onEvent: @escaping @MainActor (AgentEvent) -> Void,
             onFinish: @escaping @MainActor (AgentStatus, String?) -> Void) {
        requests.append(request)
        finish = onFinish
        onEvent(.message("ท้องฟ้าสีฟ้า"))
        onEvent(.message("ท้องฟ้าสีฟ้าเพราะแสงกระเจิง. แล้ว"))
    }
    func cancel() { finish?(.cancelled, nil); finish = nil }
    func reset() {}
}

@MainActor
struct InterruptionTests {
    @Test func cuttingInTellsTheAgentWhatWasHeard() {
        let model = AppModel(store: ChatStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("vox-\(UUID()).json")))
        model.tts.volume = 0
        model.autoSpeak = true
        defer { model.autoSpeak = false; model.cancel() }
        let runner = HangingRunner()
        model.runner = runner
        model.transcript = "ทำไมท้องฟ้าสีฟ้า"
        model.send()
        #expect(model.spokenLog == ["ท้องฟ้าสีฟ้าเพราะแสงกระเจิง."]) // spoken while the agent is still writing
        model.interrupt()
        #expect(model.phase == .idle)

        model.transcript = "แล้วสีแดงล่ะ"
        model.send()
        // The first sentence was still playing when cut off, so the user heard none of it.
        #expect(runner.requests.last?.interrupted == "")
        runner.cancel()

        model.transcript = "ขอบคุณ"
        model.send()
        #expect(runner.requests.last?.interrupted == nil) // only the request right after the cut
    }

    @Test func aRepeatedMessageIsNotSpokenAgain() {
        let model = AppModel(store: ChatStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("vox-\(UUID()).json")))
        model.tts.volume = 0
        model.autoSpeak = true
        defer { model.autoSpeak = false; model.cancel() }
        // Claude streams the text, then sends the whole message once more.
        model.runner = StreamingRunner(["สวัสดีครับ. ", "วันนี้ให้ช่วยอะไรดี", ""])
        model.transcript = "hi"
        model.send()
        #expect(model.spokenLog == ["สวัสดีครับ.", "วันนี้ให้ช่วยอะไรดี"])
    }
}
