import AVFoundation
import Foundation

/// Energy-based voice activity detection: learns the room's noise floor, notices speech, and reports the end
/// of the user's turn after a short pause — much sooner than waiting for the recognizer to go quiet.
struct EndOfTurnDetector {
    enum Event: Equatable { case none, speechStarted, endOfTurn }

    // ponytail: fixed margins tuned for a quiet room; make them settings if noisy places cut turns early or late.
    var startMargin: Float = 12 // dB above the noise floor that counts as speech
    var endMargin: Float = 6    // dB above the floor that still counts as "still talking"
    var pause: TimeInterval = 1.2 // long enough to pause and think mid-sentence

    private(set) var noiseFloor: Float?
    private(set) var speaking = false
    private var lastVoice = Date.distantPast

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
