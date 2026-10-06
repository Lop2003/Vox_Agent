import AVFoundation
import Foundation
import SoundAnalysis

/// Notices the user speaking and reports the end of their turn after a short pause — much sooner than waiting
/// for the recognizer to go quiet. Two inputs:
/// - `feed(confidence:)`: speech probability from `SpeechActivity` (preferred: ignores keyboards, fans, clicks).
/// - `feed(_ level:)`: loudness vs. a learned noise floor (fallback when the classifier isn't available;
///   steady noise is fine, but bursts like typing count as speech).
struct EndOfTurnDetector {
    enum Event: Equatable { case none, speechStarted, endOfTurn }

    // ponytail: fixed margins tuned for a quiet room; make them settings if noisy places cut turns early or late.
    var startMargin: Float = 12 // dB above the noise floor that counts as speech
    var endMargin: Float = 6    // dB above the floor that still counts as "still talking"
    var pause: TimeInterval = 1.2 // long enough to pause and think mid-sentence

    private(set) var noiseFloor: Float?
    private(set) var speaking = false
    private var lastVoice = Date.distantPast

    // Hysteresis: confident to start, more lenient to keep going through soft syllables.
    var startConfidence = 0.6
    var keepConfidence = 0.35

    mutating func feed(confidence: Double, at now: Date = Date()) -> Event {
        if !speaking {
            guard confidence >= startConfidence else { return .none }
            speaking = true
            lastVoice = now
            return .speechStarted
        }
        if confidence >= keepConfidence {
            lastVoice = now
        } else if now.timeIntervalSince(lastVoice) >= pause {
            speaking = false
            return .endOfTurn
        }
        return .none
    }

    mutating func feed(_ level: Float, at now: Date = Date()) -> Event {
        guard let floor = noiseFloor else {
            noiseFloor = level
            return .none
        }
        if !speaking {
            if level > floor + startMargin {
                speaking = true
                lastVoice = now
                return .speechStarted
            }
            noiseFloor = floor * 0.95 + level * 0.05 // drift with the room while it's quiet
            return .none
        }
        if level > floor + endMargin {
            lastVoice = now
        } else if now.timeIntervalSince(lastVoice) >= pause {
            speaking = false
            return .endOfTurn
        }
        return .none
    }

    /// RMS level of a buffer in dBFS (-160 for silence).
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -160 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        return rms > 0 ? 20 * log10(rms) : -160
    }
}

/// "Is someone talking?" from Apple's on-device sound classifier (SoundAnalysis, built-in "speech" class).
/// Measured on test clips: Thai speech found with or without noise mixed in; white noise and keyboard clicks
/// stay at 0.20–0.27 confidence, while a loudness threshold took typing for speech and never ended the turn.
final class SpeechActivity: NSObject, SNResultsObserving, @unchecked Sendable {
    /// Speech confidence 0…1, about every 0.25 s (0.5 s windows, half overlapping). Called on a background queue.
    var onConfidence: (@Sendable (Double) -> Void)?

    private let request: SNClassifySoundRequest
    private let queue = DispatchQueue(label: "voxagent.speech-activity")
    private var analyzer: SNAudioStreamAnalyzer?
    private var position: AVAudioFramePosition = 0

    /// Nil if the classifier isn't available on this device (callers fall back to loudness).
    init?(windowSeconds: Double = 0.5) {
        guard let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
        request.windowDuration = CMTime(seconds: windowSeconds, preferredTimescale: 1000)
        request.overlapFactor = 0.5
        self.request = request
    }

    /// Call from the audio tap. The buffer is copied: the engine reuses it once the tap returns.
    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
        let at = position
        position += AVAudioFramePosition(buffer.frameLength)
        queue.async { [self] in
            if analyzer == nil {
                let analyzer = SNAudioStreamAnalyzer(format: copy.format)
                guard (try? analyzer.add(request, withObserver: self)) != nil else { return }
                self.analyzer = analyzer
            }
            analyzer?.analyze(copy, atAudioFramePosition: at)
        }
    }

    /// Flushes what's left and blocks until every result has been delivered.
    func finish() {
        queue.sync { analyzer?.completeAnalysis() }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        onConfidence?(result.classification(forIdentifier: "speech")?.confidence ?? 0)
    }
}

/// Splits an answer that is still being written into pieces worth saying now, so speech starts with the
/// first sentence instead of after the whole answer.
enum SpeechChunker {
    static let boundaries: Set<Character> = [".", "!", "?", "\n", "。"]
    /// Thai rarely uses full stops; past this many characters a space is a good enough place to break.
    static let longRun = 60

    /// The next chunk after the first `spoken` characters, and where it ends. When `final`, everything left.
    static func next(in text: String, after spoken: Int, final: Bool) -> (chunk: String, end: Int)? {
        guard spoken < text.count else { return nil }
        let rest = Array(text.dropFirst(spoken))
        var cut: Int?
        if final {
            cut = rest.count
        } else if let i = rest.lastIndex(where: { boundaries.contains($0) }) {
            cut = i + 1
        } else if rest.count >= longRun, let i = rest.lastIndex(of: " ") {
            cut = i + 1
        }
        guard let cut else { return nil }
        let chunk = String(rest[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        return chunk.isEmpty ? (final ? nil : ("", spoken + cut)) : (chunk, spoken + cut)
    }
}

/// Whether what the microphone heard is just the app's own voice coming back through the speaker.
/// Compares character pairs, which works for Thai (no spaces between words) as well as English.
enum EchoGuard {
    static func isEcho(_ heard: String, of spoken: String) -> Bool {
        let heardPairs = pairs(heard)
        guard heardPairs.count >= 2 else { return true } // a sound ("อืม", a breath), not words; "หยุด" still counts
        let spokenPairs = Set(pairs(spoken))
        let overlap = heardPairs.filter(spokenPairs.contains).count
        return Double(overlap) / Double(heardPairs.count) >= 0.5
    }

    private static func pairs(_ text: String) -> [String] {
        let letters = text.lowercased().filter { $0.isLetter || $0.isNumber }
        let chars = Array(letters)
        guard chars.count >= 2 else { return [] }
        return (0..<chars.count - 1).map { String(chars[$0...$0 + 1]) }
    }
}

/// Spoken requests are easy to mishear ("markdown" → "มาร์คดาว"), so ones that look like they change files are
/// confirmed before the coding agent runs them.
enum ChangeIntent {
    // ponytail: keyword match, not understanding; misses unusual phrasings. Ask the agent for a plan first if it matters.
    static let words = [
        "แก้", "สร้าง", "ลบ", "เพิ่ม", "เขียน", "เปลี่ยน", "ย้าย", "ติดตั้ง", "อัปเดต", "อัพเดท", "อัพเดต", "ทำไฟล์", "เปลี่ยนชื่อ",
        "fix", "create", "delete", "remove", "add", "write", "edit", "change", "rename", "refactor", "update",
        "install", "implement", "generate", "deploy", "commit", "push", "merge", "migrate",
    ]

    static func mayChangeFiles(_ request: String) -> Bool {
        let text = request.lowercased()
        return words.contains { text.contains($0) }
    }
}

/// A spoken yes/no to a confirmation question. Anything else is treated as a new request.
enum SpokenAnswer: Equatable {
    case yes, no, other

    init(_ text: String) {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        // "No" first: "ไม่ใช่" contains "ใช่", "ไม่ได้" contains "ได้".
        let no = ["ไม่", "ยกเลิก", "อย่า", "หยุด", "no", "nope", "cancel", "stop", "don't"]
        let yes = ["ใช่", "ได้", "โอเค", "ตกลง", "ยืนยัน", "เอาเลย", "ทำเลย", "จัดไป", "ถูกต้อง", "ok", "okay", "yes", "yeah", "yep", "sure", "go ahead", "confirm"]
        // Only short replies count: "ได้ แต่แก้ไฟล์อื่นแทน" is a new instruction, not a yes.
        guard t.count <= 20 else { self = .other; return }
        if no.contains(where: t.contains) { self = .no } else if yes.contains(where: t.contains) { self = .yes } else { self = .other }
    }
}
