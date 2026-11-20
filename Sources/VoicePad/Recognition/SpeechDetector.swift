import Foundation

/// Answers one question about a finished take: did anyone speak in it?
///
/// `InputSignal` can only see that the route delivered *something*; a key press on the
/// remote delivers a clipped low-frequency thump that carries plenty of energy (measured:
/// peak 1.0, 0.9 s decay) and Whisper turns it into a one-character word (`我`, `好`, `I.`,
/// `The.` all appear in the archive from takes where nothing was said). Silero VAD, which
/// sherpa-onnx already links, separates speech from thumps properly, so the decision is
/// made on a speech probability instead of on level.
///
/// The model is optional: without `silero_vad.onnx` this returns `nil` and the caller keeps
/// the level gate only, so a missing file can never take dictation away.
final class SpeechDetector {
    private let vad: OpaquePointer
    private let windowSize = 512
    private let lock = NSLock()

    /// `~/.voicepad/models/silero-vad/silero_vad.onnx`, downloaded once next to the ASR model.
    static var defaultModelPath: String {
        ConfigDirectory.path + "/models/silero-vad/silero_vad.onnx"
    }

    init?(modelPath: String = SpeechDetector.defaultModelPath) {
        guard FileManager.default.fileExists(atPath: modelPath) else { return nil }

        var config = SherpaOnnxVadModelConfig()
        memset(&config, 0, MemoryLayout.size(ofValue: config))
        config.silero_vad.model = UnsafePointer(strdup(modelPath)!)
        config.silero_vad.threshold = 0.5
        // A single syllable ("好", "继续") lasts about 0.2 s; keeping the floor below that
        // stops the detector from throwing away short real dictations.
        config.silero_vad.min_speech_duration = 0.15
        config.silero_vad.min_silence_duration = 0.25
        config.silero_vad.max_speech_duration = 30
        config.silero_vad.window_size = 512
        config.sample_rate = 16_000
        config.num_threads = 1
        config.provider = UnsafePointer(strdup("cpu")!)
        config.debug = 0

        guard let vad = SherpaOnnxCreateVoiceActivityDetector(&config, 30) else { return nil }
        self.vad = vad
        vpLog("[SpeechDetector] Silero VAD ready")
    }

    deinit {
        SherpaOnnxDestroyVoiceActivityDetector(vad)
    }

    /// True when the take contains at least one stretch of speech.
    func containsSpeech(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }

        SherpaOnnxVoiceActivityDetectorReset(vad)
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var index = 0
            while index + windowSize <= samples.count {
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, base + index, Int32(windowSize))
                index += windowSize
            }
            // A take that ends while the speaker is still talking never closes a segment,
            // so the remainder goes in and the detector is flushed before asking.
            if index < samples.count {
                SherpaOnnxVoiceActivityDetectorAcceptWaveform(
                    vad, base + index, Int32(samples.count - index)
                )
            }
        }
        SherpaOnnxVoiceActivityDetectorFlush(vad)

        let hasSegment = SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0
        let inSpeech = SherpaOnnxVoiceActivityDetectorDetected(vad) == 1
        return hasSegment || inSpeech
    }
}
