import Foundation
import Testing
import VoxCodeCore
@testable import VoxUI

/// Answers every request immediately, like a very fast agent.
@MainActor
private final class FakeRunner: AgentRunner {
    var agents = ["Fake"]
    var resets = 0
    func run(_ text: String, agent: String, activeFile: String?, language: String?,
             onEvent: @escaping @MainActor (AgentEvent) -> Void,
             onFinish: @escaping @MainActor (AgentStatus, String?) -> Void) {
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
