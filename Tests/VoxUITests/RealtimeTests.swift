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
