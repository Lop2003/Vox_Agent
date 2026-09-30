// Speech server for the bridge: turns text into AAC audio with this Mac's most natural voice.
//
// Run it through the Swift interpreter (`swift tts-server.swift`), not as a compiled binary: macOS only
// lets Apple-signed processes use the neural "Siri" voices, and the interpreter is Apple-signed.
//
// Protocol: one JSON object per line.
//   stdin:  {"id": 1, "text": "สวัสดี", "out": "/tmp/x.m4a"}
//   stdout: {"id": 1, "ok": true}   or   {"id": 1, "error": "..."}
// Prints {"ready": true, "voices": {...}} once it has started.
import AVFoundation
import NaturalLanguage

struct Job: Decodable { let id: Int; let text: String; let out: String }

/// Thai unless the text is clearly English; premium > enhanced > compact.
func voice(for text: String) -> AVSpeechSynthesisVoice? {
    let language = NLLanguageRecognizer.dominantLanguage(for: text) == .english ? "en-US" : "th-TH"
    return AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language == language }
        .max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: language)
}

func reply(_ object: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: object)
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

let synthesizer = AVSpeechSynthesizer()
var queue: [Job] = []
var busy = false

/// Synthesizes jobs one at a time; buffers arrive on the main run loop.
func next() {
    guard !busy, !queue.isEmpty else { return }
    busy = true
    let job = queue.removeFirst()
    let utterance = AVSpeechUtterance(string: job.text)
    utterance.voice = voice(for: job.text)
    var file: AVAudioFile?
    var failure: String?
    synthesizer.write(utterance) { buffer in
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
            file = nil // finalizes the file
            if let failure { reply(["id": job.id, "error": failure]) } else { reply(["id": job.id, "ok": true]) }
            busy = false
            next()
            return
        }
        guard failure == nil else { return }
        do {
            if file == nil {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: pcm.format.sampleRate,
                    AVNumberOfChannelsKey: pcm.format.channelCount,
                    AVEncoderBitRateKey: 64_000,
                ]
                file = try AVAudioFile(forWriting: URL(fileURLWithPath: job.out), settings: settings,
                                       commonFormat: pcm.format.commonFormat, interleaved: pcm.format.isInterleaved)
            }
            try file?.write(from: pcm)
        } catch {
            failure = error.localizedDescription
        }
    }
}

// Read jobs off the main thread; the synthesizer needs the main run loop free.
Thread.detachNewThread {
    while let line = readLine() {
        guard let job = try? JSONDecoder().decode(Job.self, from: Data(line.utf8)) else { continue }
        DispatchQueue.main.async { queue.append(job); next() }
    }
    exit(0) // the bridge went away
}

reply(["ready": true, "voices": ["th-TH": voice(for: "สวัสดี")?.name ?? "none", "en-US": voice(for: "Hello there")?.name ?? "none"]])
RunLoop.main.run()
