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
