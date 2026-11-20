import Foundation
import Testing

@testable import VoicePad

@Suite("SpeechDetector")
struct SpeechDetectorTests {

    /// The VAD model is an optional download, so a missing file must degrade to the
    /// level gate instead of taking dictation away.
    @Test("Missing model yields no detector")
    func missingModel() {
        #expect(SpeechDetector(modelPath: "/nonexistent/silero_vad.onnx") == nil)
    }

    /// Digital silence is not speech, confirmed end to end against the real model when
    /// it is installed on this machine.
    @Test("Silence contains no speech")
    func silence() async {
        guard let detector = SpeechDetector() else { return } // model not installed here
        #expect(!detector.containsSpeech([Float](repeating: 0, count: 16_000)))
    }

    @Test("Empty take contains no speech")
    func empty() async {
        guard let detector = SpeechDetector() else { return }
        #expect(!detector.containsSpeech([]))
    }
}
