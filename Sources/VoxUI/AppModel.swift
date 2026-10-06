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

    /// Workspaces from the runner (the project folder and General), each with its own agents and chats.
    public var workspaces: [AgentWorkspace] { runner?.workspaces ?? [] }
    /// Selected workspace id; falls back to the first one when the runner doesn't offer it.
    /// Switching starts a new conversation, since chats belong to one workspace.
    public var workspaceID: String {
        get { workspaces.contains { $0.id == storedWorkspace } ? storedWorkspace : workspaces.first?.id ?? storedWorkspace }
        set {
            guard newValue != workspaceID else { return }
            newConversation()
            storedWorkspace = newValue
        }
    }
    private var storedWorkspace = UserDefaults.standard.string(forKey: "workspace") ?? AgentWorkspace.code {
        didSet { UserDefaults.standard.set(storedWorkspace, forKey: "workspace") }
    }
    public var inGeneralWorkspace: Bool { workspaceID == AgentWorkspace.general }

    /// Selected agent name; falls back to the workspace's first agent when it doesn't offer this one.
    public var agent: String {
        get {
            let agents = self.agents
            return agents.contains(storedAgent) ? storedAgent : agents.first ?? storedAgent
        }
        set { storedAgent = newValue }
    }
    public var agents: [String] { workspaces.first { $0.id == workspaceID }?.agents ?? [] }
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

    /// Fallback end-of-turn wait after the last recognized word (the level detector usually ends it sooner).
    let silenceTimeout: Duration = .milliseconds(2000)

    /// In a call, keep the mic open while answering so saying "หยุด" (or anything) cuts in. Uses echo
    /// cancellation plus an echo check; turn off if the app interrupts itself through loud speakers.
    public var bargeInEnabled = UserDefaults.standard.object(forKey: "bargeIn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(bargeInEnabled, forKey: "bargeIn") }
    }

    private let voice = VoiceInputManager()
    private let stt = SpeechToTextService()
    let tts = TextToSpeechService() // internal: tests mute it
    /// Everything handed to speech, newest last (tests; capped).
    private(set) var spokenLog: [String] = []
    private var silenceTask: Task<Void, Never>?
    private var sendAfterTranscribing = false
    private var isStartingToListen = false
    private var recognitionFailures = 0
    /// The turn being read aloud, so its card can show a stop button.
    public private(set) var speakingTurn: UUID?
    /// Latest agent sentence in call mode, spoken once the agent moves on to its next step.
    private var narration: String?
    private var micOpen = false
    /// Mic open during our own speech, only to notice the user cutting in.
    private var bargeInListening = false
    /// Characters of the recognizer's text that were our own echo, not the user.
    private var heardOffset = 0
    private var vad = EndOfTurnDetector()
    /// Speech classifier for the open mic; nil when unavailable (then loudness drives end of turn).
    private var activity: SpeechActivity?
    /// Last time the classifier was sure someone was speaking.
    private var lastSpeechHeard = Date.distantPast
    /// Mic loudness 0…1 (smoothed) while in a call, for the waveform.
    public private(set) var inputLevel: Double = 0
    /// Muted in a call: the mic stays off (no listening, no interrupting) until unmuted; the call goes on.
    public private(set) var micMuted = false
    /// What we said recently, to recognize it if the mic picks it up.
    private var recentSpeech = ""
    /// The answer is arriving token by token (local models): speak it sentence by sentence as it comes.
    private var streamingAnswer = false
    private var spokenCharacters = 0

    /// Saved chats, newest first (includes the current one once it has a turn).
    public private(set) var conversations: [Conversation]
    /// Saved chats of the current workspace, newest first.
    public var workspaceConversations: [Conversation] {
        conversations.filter { ($0.workspace ?? AgentWorkspace.code) == workspaceID }
    }
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

    /// Mute or unmute the mic during a call, like a phone's mute button. Muting drops what was being said.
    public func toggleMute() {
        micMuted.toggle()
        if micMuted {
            silenceTask?.cancel()
            if micOpen {
                closeMic()
                stt.cancel()
            }
            if phase == .listening || phase == .transcribing {
                transcript = ""
                phase = .idle
            }
        } else if inCall, phase == .idle, !isSpeaking {
            Task { await startListening() }
        }
    }

    /// In a call: stop the agent's work or its voice and go back to listening, without hanging up.
    public func interrupt() {
        if phase == .running { runner?.cancel() } // finish(turn:) then listens again
        tts.stop()                                 // speechFinished() then listens again
    }

    private func speechFinished() {
        isSpeaking = false
        speakingTurn = nil
        guard inCall, phase == .idle else { return }
        if bargeInListening { beginTurn() } else { Task { await startListening() } }
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
        recentSpeech = String((recentSpeech + " " + text).suffix(400))
        spokenLog = Array((spokenLog + [text]).suffix(50))
        do {
            try tts.enqueue(text)
            isSpeaking = true
        } catch {
            errorMessage = error.localizedDescription
        }
        if inCall, bargeInEnabled, !micOpen { Task { await startListening(bargeIn: true) } }
    }

    /// Speaks the parts of a still-growing answer that are complete sentences (all of it when `final`).
    private func speakStream(_ response: String, final: Bool) {
        // A heading still being typed ("## Sum") would be read as words; wait for its line to finish.
        if response.hasPrefix("#"), !response.contains("\n") { return }
        let speakable = SpeechText.speakable(from: response)
        while let (chunk, end) = SpeechChunker.next(in: speakable, after: spokenCharacters, final: final) {
            spokenCharacters = end
            if !chunk.isEmpty { say(chunk) }
            if final { break }
        }
    }

    private var speaksAnswers: Bool { inCall || autoSpeak }

    private func sayNarration() {
        if let narration { say(narration) }
        narration = nil
    }

    private func cue(for status: AgentStatus) -> String? {
        let thai = localeID.hasPrefix("th")
        switch status {
        case .analyzing where inGeneralWorkspace: return thai ? "ขอคิดแป๊บนึง" : "Let me think"
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

    /// - Parameter bargeIn: open the mic *while* the answer plays (call mode) only to catch the user cutting in.
    ///   The phase is left alone until real, non-echo words are heard.
    private func startListening(bargeIn: Bool = false) async {
        if micMuted { return } // every automatic "listen again" path stops here while muted
        if micOpen {
            if !bargeIn, bargeInListening { // already listening for interruptions: it's the user's turn now
                tts.stop()
                beginTurn()
            }
            return
        }
        guard !isStartingToListen, bargeIn ? (phase == .idle || phase == .running) : phase == .idle else { return }
        isStartingToListen = true
        defer { isStartingToListen = false }
        if !bargeIn {
            errorMessage = nil
            tts.stop() // lets the user cut in while the answer is being read
        }
        do {
            try await VoiceInputManager.requestPermissions()
            transcript = ""
            heardOffset = 0
            sendAfterTranscribing = shouldSend // if the recognizer ends the session on its own
            let sink = try stt.start(
                localeID: localeID,
                onText: { [weak self] text, isFinal in self?.received(text, isFinal: isFinal) },
                onError: { [weak self] error in self?.recognitionFailed(error) }
            )
            // iPhone: always use voice processing (noise suppression). Mac: only when the mic must ignore our own voice.
            #if os(iOS)
            voice.voiceProcessing = true
            #else
            voice.voiceProcessing = inCall && bargeInEnabled
            #endif
            let activity = SpeechActivity()
            activity?.onConfidence = { [weak self] confidence in
                Task { @MainActor in self?.heard(confidence: confidence) }
            }
            self.activity = activity
            try voice.start { [weak self] buffer in
                sink(buffer)
                activity?.feed(buffer)
                let level = EndOfTurnDetector.level(of: buffer)
                Task { @MainActor in self?.heard(level: level) }
            }
            micOpen = true
            if bargeIn { bargeInListening = true } else { beginTurn() }
        } catch {
            stt.cancel()
            guard !bargeIn else { return } // interruptions are a bonus; the normal turn still follows
            inCall = false
            errorMessage = error.localizedDescription
        }
    }

    /// The mic is now taking the user's turn (possibly converted from watching for interruptions).
    private func beginTurn() {
        bargeInListening = false
        vad = EndOfTurnDetector()
        sendAfterTranscribing = shouldSend
        phase = .listening
    }

    private func closeMic() {
        voice.stop()
        inputLevel = 0
        activity = nil
        micOpen = false
        bargeInListening = false
    }

    /// Voice activity: end the turn as soon as the user pauses instead of waiting for the recognizer.
    /// The speech classifier drives it when available; loudness is only the fallback.
    private func heard(confidence: Double) {
        guard micOpen else { return }
        if confidence >= vad.startConfidence { lastSpeechHeard = Date() }
        guard phase == .listening else { return }
        if vad.feed(confidence: confidence) == .endOfTurn, !transcript.isEmpty { stopListening(send: shouldSend) }
    }

    private func heard(level: Float) {
        if inCall, micOpen {
            // -60 dB (quiet room) … -15 dB (close speech) → 0…1; rise fast, fall slowly so the bars don't flicker.
            let normalized = min(1, max(0, Double(level + 60) / 45))
            inputLevel = max(normalized, inputLevel * 0.85)
        }
        guard micOpen, activity == nil, phase == .listening else { return }
        if vad.feed(level) == .endOfTurn, !transcript.isEmpty { stopListening(send: shouldSend) }
    }

    public func stopListening(send: Bool) {
        guard phase == .listening else { return }
        silenceTask?.cancel()
        closeMic()
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
        if bargeInListening {
            // Watching for an interruption while the answer plays. The recognizer keeps everything it heard,
            // so only judge what came after the last echo.
            let new = String(text.dropFirst(heardOffset))
            if isFinal || EchoGuard.isEcho(new, of: recentSpeech) {
                heardOffset = text.count
                if isFinal { restartBargeIn() } // the recognizer ended its session; keep watching
                return
            }
            // Words the recognizer made out of noise: only cut in when the classifier also hears a voice.
            // (Not marked as echo: the classifier may just be a moment behind; the next partial decides.)
            if activity != nil, Date().timeIntervalSince(lastSpeechHeard) > 1.0 { return }
            // Real words over our own voice: stop talking (and the agent, if it's still writing) and listen.
            tts.stop()
            if phase == .running { runner?.cancel() }
            beginTurn()
        }
        guard phase == .listening || phase == .transcribing else { return }
        recognitionFailures = 0
        transcript = String(text.dropFirst(heardOffset)).trimmingCharacters(in: .whitespaces)
        if isFinal {
            if phase == .listening { closeMic() }
            transcriptionDone()
        } else if phase == .listening {
            // Fallback end of turn in case the level detector misses it (e.g. a quiet voice it never heard start).
            silenceTask?.cancel()
            silenceTask = Task { [weak self] in
                try? await Task.sleep(for: self?.silenceTimeout ?? .seconds(2))
                if !Task.isCancelled { self?.stopListening(send: self?.shouldSend ?? false) }
            }
        }
    }

    private func restartBargeIn() {
        closeMic()
        stt.cancel()
        if inCall, isSpeaking || phase == .running { Task { await startListening(bargeIn: true) } }
    }

    private func recognitionFailed(_ error: Error) {
        if bargeInListening { // watching for interruptions is best effort: stop quietly
            closeMic()
            stt.cancel()
            return
        }
        guard phase == .listening || phase == .transcribing else { return }
        closeMic()
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
        streamingAnswer = false
        spokenCharacters = 0
        persist()
        transcript = ""
        phase = .running
        if inCall, let ack = cue(for: .analyzing) { say(ack) } // acknowledge right away, like a person would

        runner.run(text, agent: kind, activeFile: activeFile.isEmpty ? nil : activeFile, language: localeID,
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
            let previous = turns[i].response
            turns[i].response = text
            guard speaksAnswers else { break }
            // The same message growing = a model streaming tokens; separate messages = agent narration.
            if !previous.isEmpty, text.count > previous.count, text.hasPrefix(previous) {
                streamingAnswer = true
                narration = nil
            }
            if streamingAnswer { speakStream(text, final: false) } else if inCall { narration = text }
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
        let streamed = streamingAnswer
        streamingAnswer = false
        if streamed, status == .completed, speaksAnswers {
            speakStream(turns[i].response, final: true) // the rest; earlier sentences were spoken as they arrived
            if inCall, !isSpeaking { Task { await startListening() } }
            return
        }
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
        micMuted = false
        narration = nil
        if micOpen {
            closeMic()
            stt.cancel()
        }
        switch phase {
        case .listening, .transcribing:
            silenceTask?.cancel()
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
        conversations.insert(Conversation(id: conversationID, turns: turns, updatedAt: Date(), workspace: workspaceID), at: 0)
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
        let text = SpeechText.speakable(from: response)
        spokenLog = Array((spokenLog + [text]).suffix(50))
        do {
            try tts.speak(text)
            isSpeaking = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
