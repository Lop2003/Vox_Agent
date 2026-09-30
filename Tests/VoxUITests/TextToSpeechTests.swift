import Testing
@testable import VoxUI

/// Call mode starts listening again from `onFinish`. It used to check `isSpeaking` inside didFinish, which is
/// still true at that point, so the call never went back to listening. These pin the queue-empty signal.
@MainActor
struct TextToSpeechTests {
    @Test func finishesOnceAfterEverythingQueuedIsSpoken() async throws {
        let tts = TextToSpeechService()
        tts.volume = 0
        var finishes = 0
        tts.onFinish = { finishes += 1 }
        try tts.enqueue("one")
        try tts.enqueue("two")
        for _ in 0..<200 where finishes == 0 { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(500)) // no second call from the other utterance
        #expect(finishes == 1)
    }

    @Test func stopFinishesOnceAndIgnoresLateCallbacks() async throws {
        let tts = TextToSpeechService()
        tts.volume = 0
        var finishes = 0
        tts.onFinish = { finishes += 1 }
        try tts.enqueue("a fairly long sentence so that it is still playing when we stop it")
        try await Task.sleep(for: .milliseconds(300))
        tts.stop()
        #expect(finishes == 1)
        try await Task.sleep(for: .milliseconds(800)) // didCancel arrives late; must not fire again
        #expect(finishes == 1)
    }

    @Test func stopWhenIdleDoesNothing() {
        let tts = TextToSpeechService()
        var finishes = 0
        tts.onFinish = { finishes += 1 }
        tts.stop()
        #expect(finishes == 0)
    }
}

import AVFoundation
import Foundation

/// Bridge (remote) playback path: sentences play in order and `onFinish` still fires exactly once.
@MainActor
struct RemoteSpeechTests {
    /// A short real audio clip, made with the system `say` command.
    private func clip(_ text: String) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: url) }
        return try Data(contentsOf: url)
    }

    @Test func playsRemoteAudioInOrderThenFinishesOnce() async throws {
        let tts = TextToSpeechService()
        tts.volume = 0
        let one = try clip("one"), two = try clip("two")
        var requested: [String] = []
        tts.remote = { text in
            requested.append(text)
            return text == "1" ? one : two
        }
        var finishes = 0
        tts.onFinish = { finishes += 1 }
        try tts.enqueue("1")
        try tts.enqueue("2")
        for _ in 0..<200 where finishes == 0 { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(400))
        #expect(finishes == 1)
        #expect(requested == ["1", "2"])
    }

    @Test func fallsBackToLocalVoiceWhenRemoteFails() async throws {
        let tts = TextToSpeechService()
        tts.volume = 0
        tts.remote = { _ in throw CancellationError() }
        var finishes = 0
        tts.onFinish = { finishes += 1 }
        try tts.enqueue("fallback")
        for _ in 0..<200 where finishes == 0 { try await Task.sleep(for: .milliseconds(50)) }
        #expect(finishes == 1)
    }

    @Test func stopDuringRemotePlaybackFinishesOnce() async throws {
        let tts = TextToSpeechService()
        tts.volume = 0
        let long = try clip("this is a longer sentence that keeps playing for a while")
        tts.remote = { _ in long }
        var finishes = 0
        tts.onFinish = { finishes += 1 }
        try tts.enqueue("a")
        try tts.enqueue("b")
        try await Task.sleep(for: .milliseconds(500))
        tts.stop()
        #expect(finishes == 1)
        try await Task.sleep(for: .milliseconds(800))
        #expect(finishes == 1)
    }
}
