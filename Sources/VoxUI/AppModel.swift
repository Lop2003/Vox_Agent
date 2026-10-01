import Foundation
import Observation
import VoxCodeCore

public struct Turn: Identifiable, Codable, Equatable {
    public var id = UUID()
    public let user: String
    public let agent: String
    public var response = ""
    public var activity: [String] = []
    public var status = AgentStatus.analyzing
    public var error: String?
}

/// Application state and the voice → agent → speech loop, shared by the Mac and iPhone apps.
/// Where the agent actually runs is up to `runner` (the bridge, via `BridgeClient`). Chats are saved to `store`.
@MainActor @Observable
public final class AppModel {
    public enum Phase: Equatable { case idle, listening, transcribing, running }

    public var phase = Phase.idle
    public var transcript = ""
    public private(set) var turns: [Turn] = []
    public var errorMessage: String?
    public private(set) var isSpeaking = false
    /// Hands-free "phone call": listen → send → narrate progress → read the answer → listen again.
    public private(set) var inCall = false

    public var runner: (any AgentRunner)?
    /// Shown when the user sends without a runner, e.g. "Choose a workspace folder first."
    public var runnerMissingMessage = "No agent available."

    /// Selected agent name; falls back to the runner's first agent when it doesn't offer this one.
    public var agent: String {
        get {
            let agents = self.agents
            return agents.contains(storedAgent) ? storedAgent : agents.first ?? storedAgent
        }
        set { storedAgent = newValue }
    }
    public var agents: [String] { runner?.agents ?? [] }
    private var storedAgent = UserDefaults.standard.string(forKey: "agent") ?? "Claude Code" {
        didSet { UserDefaults.standard.set(storedAgent, forKey: "agent") }
    }
    public var localeID = UserDefaults.standard.string(forKey: "locale") ?? "th-TH" {
        didSet { UserDefaults.standard.set(localeID, forKey: "locale") }
    }
    public var autoSend = UserDefaults.standard.object(forKey: "autoSend") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSend, forKey: "autoSend") }
    }
    public var autoSpeak = UserDefaults.standard.bool(forKey: "autoSpeak") {
        didSet { UserDefaults.standard.set(autoSpeak, forKey: "autoSpeak") }
    }
    public var activeFile = ""

    /// Thai voice identifier, "" for the best installed one. Changing it plays a short sample.
    public var thaiVoice = VoiceCatalog.preferredID(for: "th-TH") {
        didSet {
            VoiceCatalog.setPreferredID(thaiVoice, for: "th-TH")
            prepareVoice()
            try? tts.speak("สวัสดีครับ นี่คือเสียงที่จะใช้ตอบคุณ")
            isSpeaking = true
        }
    }

    let silenceTimeout: Duration = .seconds(2)

    private let voice = VoiceInputManager()
    private let stt = SpeechToTextService()
    private let tts = TextToSpeechService()
    private var silenceTask: Task<Void, Never>?
    private var sendAfterTranscribing = false
    private var isStartingToListen = false
    private var recognitionFailures = 0
    /// The turn being read aloud, so its card can show a stop button.
    public private(set) var speakingTurn: UUID?
    /// Latest agent sentence in call mode, spoken once the agent moves on to its next step.
    private var narration: String?

    /// Saved chats, newest first (includes the current one once it has a turn).
    public private(set) var conversations: [Conversation]
    public private(set) var conversationID = UUID()
    private let store: ChatStore

    public init(store: ChatStore = .standard) {
        self.store = store
        conversations = store.load()
        tts.onFinish = { [weak self] in self?.speechFinished() }
    }

    private var shouldSend: Bool { autoSend || inCall }

    public var currentStatus: AgentStatus { turns.last?.status ?? .idle }
    public var lastResponse: String? { turns.last(where: { !$0.response.isEmpty })?.response }

    public var phaseLabel: String {
        switch phase {
        case .idle where inCall: isSpeaking ? "In call · Speaking…" : "In call"
        case .idle: currentStatus == .idle ? "Ready" : currentStatus.rawValue
        case .listening: inCall ? "In call · Listening…" : "Listening…"
        case .transcribing: "Transcribing…"
        case .running: "Running \(turns.last?.agent ?? agent)… · \(currentStatus.rawValue)"
        }
    }

    // MARK: Call mode

    public func toggleCall() {
        if inCall { return cancel() }
        inCall = true
        recognitionFailures = 0
        errorMessage = nil
        if phase == .idle { Task { await startListening() } }
    }

    private func speechFinished() {
        isSpeaking = false
        speakingTurn = nil
        if inCall, phase == .idle { Task { await startListening() } }
    }

    /// Automatic voice = the bridge's Mac neural voice when it offers one (far more natural than the
    /// phone's, and the only good Thai voice in the Simulator); a specific voice = that local voice.
    private func prepareVoice() {
        if thaiVoice.isEmpty, let bridge = runner as? BridgeClient, bridge.canSpeak {
            tts.remote = { [weak bridge] text in
                guard let bridge else { throw CancellationError() }
                return try await bridge.synthesize(text)
            }
        } else {
            tts.remote = nil
        }
    }

    /// Speaks without interrupting what is already being said.
    private func say(_ text: String) {
        let text = SpeechText.strip(text)
        guard !text.isEmpty else { return }
        prepareVoice()
        do {
            try tts.enqueue(text)
            isSpeaking = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func sayNarration() {
        if let narration { say(narration) }
        narration = nil
    }

    private func cue(for status: AgentStatus) -> String? {
        let thai = localeID.hasPrefix("th")
        switch status {
        case .analyzing: return thai ? "กำลังดูโค้ด" : "Looking at the code"
        case .editing: return thai ? "กำลังแก้ไฟล์" : "Editing files"
        case .testing: return thai ? "กำลังรันเทส" : "Running checks"
        default: return nil
        }
    }

    // MARK: Voice input

    public func toggleListening() {
        switch phase {
        case .idle: Task { await startListening() }
        case .listening: stopListening(send: shouldSend)
        case .transcribing, .running: break
        }
    }

    private func startListening() async {
        guard phase == .idle, !isStartingToListen else { return }
        isStartingToListen = true
        defer { isStartingToListen = false }
        errorMessage = nil
        tts.stop() // lets the user cut in while the answer is being read
        do {
            try await VoiceInputManager.requestPermissions()
            transcript = ""
            sendAfterTranscribing = shouldSend // if the recognizer ends the session on its own
            let sink = try stt.start(
                localeID: localeID,
                onText: { [weak self] text, isFinal in self?.received(text, isFinal: isFinal) },
                onError: { [weak self] error in self?.recognitionFailed(error) }
            )
            try voice.start(onBuffer: sink)
            phase = .listening
        } catch {
            stt.cancel()
            inCall = false
            errorMessage = error.localizedDescription
        }
    }

    public func stopListening(send: Bool) {
        guard phase == .listening else { return }
        silenceTask?.cancel()
        voice.stop()
        stt.finish()
        sendAfterTranscribing = send
        phase = .transcribing
        // Don't wait forever for the recognizer's final result.
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { self?.transcriptionDone() }
        }
    }

    private func received(_ text: String, isFinal: Bool) {
        guard phase == .listening || phase == .transcribing else { return }
        recognitionFailures = 0
        transcript = text
        if isFinal {
            if phase == .listening { voice.stop() }
            transcriptionDone()
        } else if phase == .listening {
            // Auto-stop once the user pauses.
            silenceTask?.cancel()
            silenceTask = Task { [weak self, silenceTimeout] in
                try? await Task.sleep(for: silenceTimeout)
                if !Task.isCancelled { self?.stopListening(send: self?.shouldSend ?? false) }
            }
        }
    }

    private func recognitionFailed(_ error: Error) {
        guard phase == .listening || phase == .transcribing else { return }
        voice.stop()
        if transcript.isEmpty {
            silenceTask?.cancel()
            stt.cancel()
            phase = .idle
            // 1110 = "No speech detected". In a call, silence and hiccups just mean listen again;
            // give up only if recognition keeps failing, so a broken recognizer can't loop forever.
            let noSpeech = (error as NSError).code == 1110
            if inCall, noSpeech || recognitionFailures < 3 {
                if !noSpeech { recognitionFailures += 1 }
                Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    await startListening()
                }
                return
            }
            inCall = false
            errorMessage = noSpeech ? "No speech detected. Try again." : "Speech recognition failed: \(error.localizedDescription)"
        } else {
            transcriptionDone()
        }
    }

    private func transcriptionDone() {
        guard phase == .listening || phase == .transcribing else { return }
        silenceTask?.cancel()
        stt.cancel()
        phase = .idle
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if inCall { Task { await startListening() } } else { errorMessage = "No speech detected. Try again." }
        } else if sendAfterTranscribing {
            send()
        }
    }

    // MARK: Agent

    public func send() {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase == .idle else { return }
        guard !text.isEmpty else { errorMessage = "Nothing to send: the transcription is empty."; return }
        guard let runner else { errorMessage = runnerMissingMessage; return }

        errorMessage = nil
        tts.stop()
        let kind = agent
        turns.append(Turn(user: text, agent: kind))
        let turnID = turns[turns.count - 1].id
        persist()
        transcript = ""
        phase = .running
        if inCall, let ack = cue(for: .analyzing) { say(ack) } // acknowledge right away, like a person would

        runner.run(text, agent: kind, activeFile: activeFile.isEmpty ? nil : activeFile,
                   onEvent: { [weak self] event in self?.handle(event, turn: turnID) },
                   onFinish: { [weak self] status, error in self?.finish(turn: turnID, status: status, error: error) })
    }

    private func handle(_ event: AgentEvent, turn id: UUID) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .status(let status):
            if inCall {
                // Say what the agent announced, or a short cue when the step changes silently.
                if narration != nil { sayNarration() } else if status != turns[i].status, let cue = cue(for: status) { say(cue) }
            }
            turns[i].status = status
        case .activity(let line):
            if inCall { sayNarration() }
            turns[i].activity.append(line)
        case .message(let text):
            if inCall { narration = text }
            turns[i].response = text
        case .completed(let text) where !text.isEmpty: turns[i].response = text
        case .completed, .session, .failed: break // session and final status are the runner's job
        }
    }

    private func finish(turn id: UUID, status: AgentStatus, error: String?) {
        guard let i = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[i].status = status
        turns[i].error = error
        persist()
        guard turns[i].id == turns.last?.id, phase == .running else { return }
        phase = .idle
        narration = nil // the last message is the answer itself
        if inCall {
            switch status {
            case .completed: say(SpeechText.speakable(from: turns[i].response))
            case .failed: say((localeID.hasPrefix("th") ? "ไม่สำเร็จ " : "That failed. ") + (error ?? ""))
            default: break
            }
            if !isSpeaking { Task { await startListening() } }
        } else if status == .completed, autoSpeak {
            speakLastResponse()
        }
    }

    /// Stops whatever is happening and hangs up a call.
    public func cancel() {
        inCall = false
        narration = nil
        switch phase {
        case .listening, .transcribing:
            silenceTask?.cancel()
            voice.stop()
            stt.cancel()
            phase = .idle
        case .running:
            runner?.cancel() // finish(turn:) follows with .cancelled
            phase = .idle
        case .idle:
            break
        }
        tts.stop()
    }

    public func newConversation() {
        cancel()
        runner?.reset()
        turns = []
        conversationID = UUID()
        errorMessage = nil
    }

    // MARK: History

    /// Shows a saved chat. The agent starts fresh: it doesn't remember that chat's context.
    public func open(_ conversation: Conversation) {
        guard conversation.id != conversationID else { return }
        cancel()
        runner?.reset()
        turns = conversation.turns
        conversationID = conversation.id
        errorMessage = nil
    }

    public func delete(_ conversation: Conversation) {
        conversations.removeAll { $0.id == conversation.id }
        store.save(conversations)
        if conversation.id == conversationID { newConversation() }
    }

    private func persist() {
        guard !turns.isEmpty else { return }
        conversations.removeAll { $0.id == conversationID }
        conversations.insert(Conversation(id: conversationID, turns: turns, updatedAt: Date()), at: 0)
        store.save(conversations)
    }

    // MARK: Speech output

    public func toggleSpeaking() {
        if isSpeaking { tts.stop() } else { speakLastResponse() }
    }

    /// Reads one answer aloud, or stops it if it is the one playing.
    public func toggleSpeaking(_ turn: Turn) {
        if speakingTurn == turn.id { return tts.stop() }
        prepareVoice()
        do {
            try tts.speak(SpeechText.speakable(from: turn.response))
            isSpeaking = true
            speakingTurn = turn.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func speakLastResponse() {
        guard let response = lastResponse else { return }
        prepareVoice()
        do {
            try tts.speak(SpeechText.speakable(from: response))
            isSpeaking = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
