import AVFoundation
import NaturalLanguage
import Speech

struct VoxError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Owns the microphone: permissions and AVAudioEngine capture.
final class VoiceInputManager {
    private let engine = AVAudioEngine()

    static func requestPermissions() async throws {
        let micGranted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micGranted = true
        case .notDetermined: micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        default: micGranted = false
        }
        guard micGranted else {
            throw VoxError("Microphone access denied. Enable Vox Agent in System Settings › Privacy & Security › Microphone.")
        }
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized else {
            throw VoxError("Speech recognition denied. Enable Vox Agent in System Settings › Privacy & Security › Speech Recognition.")
        }
    }

    /// `onBuffer` runs on the audio thread.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw VoxError("No microphone available.") }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in onBuffer(buffer) }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoxError("Could not start the microphone: \(error.localizedDescription)")
        }
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
    }
}

/// Converts streamed audio buffers to text with SFSpeechRecognizer (Thai by default).
public final class SpeechToTextService {
    public static let locales = ["th-TH": "ไทย", "en-US": "English"]

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Returns the sink to feed audio buffers into. Callbacks arrive on the main actor.
    func start(localeID: String, onText: @escaping @MainActor (_ text: String, _ isFinal: Bool) -> Void, onError: @escaping @MainActor (Error) -> Void) throws -> (AVAudioPCMBuffer) -> Void {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)), recognizer.isAvailable else {
            throw VoxError("Speech recognition for \(localeID) is not available right now.")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        // Help mixed Thai/English developer speech.
        request.contextualStrings = ["Claude Code", "Codex", "login", "rate limit", "API", "test", "build", "bug", "refactor", "commit", "endpoint", "database"]
        self.request = request
        task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString, isFinal = result.isFinal
                Task { @MainActor in onText(text, isFinal) }
            } else if let error {
                Task { @MainActor in onError(error) }
            }
        }
        return { [request] buffer in request.append(buffer) }
    }

    /// Stops listening; the final result still arrives through `onText`.
    func finish() {
        request?.endAudio()
    }

    func cancel() {
        task?.cancel()
        request = nil
        task = nil
    }
}

/// Installed text-to-speech voices. The default pick is the most natural one (premium > enhanced > compact):
/// `AVSpeechSynthesisVoice(language:)` returns the robotic compact voice even when a neural one is installed.
public enum VoiceCatalog {
    public struct Option: Hashable, Identifiable {
        public let id: String
        public let label: String
    }

    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    public static func options(for language: String) -> [Option] {
        voices(for: language).map { voice in
            let quality = switch voice.quality {
            case .premium: " · Premium"
            case .enhanced: " · Enhanced"
            default: ""
            }
            return Option(id: voice.identifier, label: voice.name + quality)
        }
    }

    /// "" means automatic (best installed voice).
    public static func preferredID(for language: String) -> String {
        UserDefaults.standard.string(forKey: "voice.\(language)") ?? ""
    }

    public static func setPreferredID(_ id: String, for language: String) {
        UserDefaults.standard.set(id, forKey: "voice.\(language)")
    }

    static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let id = preferredID(for: language)
        if !id.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: id) { return chosen }
        return voices(for: language).first ?? AVSpeechSynthesisVoice(language: language)
    }
}

/// Reads agent replies aloud with AVSpeechSynthesizer, picking a Thai or English voice.
final class TextToSpeechService: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {  // used from the main actor only
    private let synthesizer = AVSpeechSynthesizer()
    /// Fires once everything queued has been spoken or stopped.
    var onFinish: (@MainActor () -> Void)?
    // Counted by hand: `isSpeaking` is often still true inside didFinish, so it can't tell us the queue is empty.
    @MainActor private var pending = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    @MainActor func speak(_ text: String) throws {
        stop()
        try enqueue(text)
    }

    /// Speaks after whatever is already queued.
    @MainActor func enqueue(_ text: String) throws {
        let language = NLLanguageRecognizer.dominantLanguage(for: text) == .english ? "en-US" : "th-TH"
        guard let voice = VoiceCatalog.voice(for: language) ?? AVSpeechSynthesisVoice(language: "en-US") else {
            throw VoxError("No text-to-speech voice installed for \(language).")
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        pending += 1
        synthesizer.speak(utterance)
    }

    @MainActor func stop() {
        guard pending > 0 else { return }
        pending = 0 // late didCancel callbacks are ignored below
        synthesizer.stopSpeaking(at: .immediate)
        onFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { finished() }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { finished() }

    private func finished() {
        Task { @MainActor in
            guard pending > 0 else { return }
            pending -= 1
            if pending == 0 { onFinish?() }
        }
    }
}
