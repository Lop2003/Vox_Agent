import Foundation
import Testing
@testable import VoxUI

struct EndOfTurnDetectorTests {
    @Test func detectsSpeechThenEndsTurnAfterAPause() {
        var vad = EndOfTurnDetector()
        let t0 = Date()
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        #expect(vad.feed(-60, at: at(0)) == .none)          // learns the floor
        #expect(vad.feed(-58, at: at(0.1)) == .none)        // room noise
        #expect(vad.feed(-30, at: at(0.2)) == .speechStarted)
        #expect(vad.feed(-32, at: at(0.5)) == .none)        // still talking
        #expect(vad.feed(-57, at: at(0.9)) == .none)        // short gap between words
        #expect(vad.feed(-31, at: at(1.0)) == .none)
        #expect(vad.feed(-58, at: at(1.4)) == .none)
        #expect(vad.feed(-58, at: at(1.8)) == .none)        // 0.8 s thinking pause: still the user's turn
        #expect(vad.feed(-58, at: at(2.3)) == .endOfTurn)   // 1.3 s of quiet after the last word
        #expect(vad.feed(-58, at: at(2.5)) == .none)        // reported once
    }

    @Test func roomNoiseAloneNeverCountsAsSpeech() {
        var vad = EndOfTurnDetector()
        for i in 0..<50 { #expect(vad.feed(-50 + Float(i % 3), at: Date().addingTimeInterval(Double(i) * 0.05)) == .none) }
    }
}

struct SpeechChunkerTests {
    @Test func waitsForASentenceThenSpeaksIt() {
        #expect(SpeechChunker.next(in: "กำลังดู", after: 0, final: false) == nil)
        let first = SpeechChunker.next(in: "เจอแล้ว.\nกำลัง", after: 0, final: false)
        #expect(first?.chunk == "เจอแล้ว.")
        #expect(SpeechChunker.next(in: "เจอแล้ว.\nกำลังแก้", after: first!.end, final: false) == nil)
        #expect(SpeechChunker.next(in: "เจอแล้ว.\nกำลังแก้", after: first!.end, final: true)?.chunk == "กำลังแก้")
    }

    @Test func breaksLongThaiRunsAtASpace() {
        let thai = String(repeating: "ก", count: 40) + " " + String(repeating: "ข", count: 30)
        let chunk = SpeechChunker.next(in: thai, after: 0, final: false)
        #expect(chunk?.chunk == String(repeating: "ก", count: 40))
    }

    @Test func nothingLeftMeansNil() {
        #expect(SpeechChunker.next(in: "abc.", after: 4, final: true) == nil)
    }
}

struct EchoGuardTests {
    @Test func recognizesItsOwnVoice() {
        #expect(EchoGuard.isEcho("แก้ไฟล์ login เรียบร้อย", of: "แก้ไฟล์ login เรียบร้อยแล้ว เทสผ่านทั้งหมด"))
        #expect(EchoGuard.isEcho("อืม", of: "anything")) // too short to be words
    }

    @Test func letsTheUserThrough() {
        #expect(!EchoGuard.isEcho("หยุดก่อน ไปดูหน้า settings แทน", of: "แก้ไฟล์ login เรียบร้อยแล้ว เทสผ่านทั้งหมด"))
        #expect(!EchoGuard.isEcho("หยุด", of: "แก้ไฟล์ login เรียบร้อยแล้ว")) // the classic interruption
    }
}

import AVFoundation

/// Real audio through Apple's classifier: the reason it replaced the loudness threshold.
struct SpeechActivityTests {
    private static let rate = 16000.0
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!

    /// Spoken Thai from the system `say` command, resampled to 16 kHz.
    private static func speech() throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Kanya", "-o", url.path, "ช่วยตรวจสอบระบบเข้าสู่ระบบให้หน่อย แล้วแก้ให้ด้วยนะ"]
        try say.run()
        say.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: source)
        let converter = AVAudioConverter(from: file.processingFormat, to: format)!
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * rate / file.processingFormat.sampleRate) + 1024)!
        var given = false
        converter.convert(to: out, error: nil) { _, status in
            if given { status.pointee = .endOfStream; return nil }
            given = true
            status.pointee = .haveData
            return source
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    private static func noise(_ count: Int, _ amplitude: Float) -> [Float] { (0..<count).map { _ in .random(in: -amplitude...amplitude) } }

    /// Keyboard-like clicks over a quiet room: the case that fooled the loudness detector.
    private static func clicks(seconds: Double) -> [Float] {
        var samples = noise(Int(seconds * rate), 0.003)
        var t = 4000
        while t < samples.count - 400 {
            for i in 0..<240 { samples[t + i] += .random(in: -0.4...0.4) * exp(-Float(i) / 40) }
            t += .random(in: 2400...3600)
        }
        return samples
    }

    /// Runs samples through `SpeechActivity` in 1024-frame buffers, like the mic tap. Returns the peak confidence
    /// and whether the turn detector saw speech start.
    private static func analyze(_ samples: [Float]) throws -> (peak: Double, speechStarted: Bool) {
        let activity = try #require(SpeechActivity())
        let lock = NSLock()
        var confidences: [Double] = []
        activity.onConfidence = { c in lock.withLock { confidences.append(c) } }
        var offset = 0
        while offset < samples.count {
            let n = min(1024, samples.count - offset)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            buffer.frameLength = AVAudioFrameCount(n)
            for i in 0..<n { buffer.floatChannelData![0][i] = samples[offset + i] }
            activity.feed(buffer)
            offset += n
        }
        activity.finish()
        var detector = EndOfTurnDetector()
        let all = lock.withLock { confidences }
        let started = all.contains { detector.feed(confidence: $0) == .speechStarted }
        return (all.max() ?? 0, started)
    }

    @Test func findsSpeechCleanAndInNoise() throws {
        let silence = [Float](repeating: 0, count: Int(Self.rate))
        let clip = silence + (try Self.speech()) + silence
        #expect(try Self.analyze(clip).speechStarted)
        let noisy = zip(clip, Self.noise(clip.count, 0.05)).map { $0 + $1 }
        #expect(try Self.analyze(noisy).speechStarted)
    }

    @Test func ignoresNoiseAndTyping() throws {
        let noise = try Self.analyze(Self.noise(Int(Self.rate * 4), 0.2))
        #expect(!noise.speechStarted, "loud noise peaked at \(noise.peak)")
        let typing = try Self.analyze(Self.clicks(seconds: 5))
        #expect(!typing.speechStarted, "typing peaked at \(typing.peak)")
    }
}

struct ConfidenceTurnTests {
    @Test func confidenceHysteresisAndPause() {
        var vad = EndOfTurnDetector()
        let t0 = Date()
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        #expect(vad.feed(confidence: 0.5, at: at(0)) == .none)          // not sure enough to start
        #expect(vad.feed(confidence: 0.8, at: at(0.25)) == .speechStarted)
        #expect(vad.feed(confidence: 0.4, at: at(0.5)) == .none)         // soft syllable: still talking
        #expect(vad.feed(confidence: 0.1, at: at(1.0)) == .none)         // short pause
        #expect(vad.feed(confidence: 0.1, at: at(1.8)) == .endOfTurn)    // 1.3 s since the last speech
    }
}

struct ConfirmationWordsTests {
    @Test func spotsRequestsThatChangeFiles() {
        #expect(ChangeIntent.mayChangeFiles("สร้างไฟล์ markdown สรุปโปรเจกต์"))
        #expect(ChangeIntent.mayChangeFiles("ช่วยแก้ login rate limit ให้หน่อย"))
        #expect(ChangeIntent.mayChangeFiles("please fix the failing test"))
        #expect(!ChangeIntent.mayChangeFiles("โปรเจกต์นี้ทำอะไรได้บ้าง"))
        #expect(!ChangeIntent.mayChangeFiles("อธิบาย login flow ให้ฟังหน่อย"))
    }

    @Test func readsShortYesNoAnswers() {
        #expect(SpokenAnswer("ใช่") == .yes)
        #expect(SpokenAnswer("ได้เลย") == .yes)
        #expect(SpokenAnswer("โอเค") == .yes)
        #expect(SpokenAnswer("ไม่ใช่") == .no)     // contains "ใช่", still a no
        #expect(SpokenAnswer("ไม่ได้") == .no)     // contains "ได้", still a no
        #expect(SpokenAnswer("ยกเลิก") == .no)
        #expect(SpokenAnswer("ได้ แต่ช่วยแก้ไฟล์ README แทนนะ") == .other) // a new instruction, not a plain yes
        #expect(SpokenAnswer("สรุปโปรเจกต์") == .other)
    }
}
