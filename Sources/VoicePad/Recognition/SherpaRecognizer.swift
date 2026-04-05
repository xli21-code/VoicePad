import Foundation

/// Result from offline transcription.
struct TranscriptResult {
    let text: String
    let language: String?
}

/// Wraps sherpa-onnx C API for offline ASR.
final class SherpaRecognizer {
    private let modelDir: String
    private var offlineRecognizer: OpaquePointer?

    init(modelDir: String) {
        self.modelDir = modelDir
        setupOfflineRecognizer()
    }

    deinit {
        if let recognizer = offlineRecognizer {
            SherpaOnnxDestroyOfflineRecognizer(recognizer)
        }
    }

    // MARK: - Offline (final transcription)

    private func setupOfflineRecognizer() {
        // Zero-initialize the config struct (required by sherpa-onnx)
        var config = SherpaOnnxOfflineRecognizerConfig()
        memset(&config, 0, MemoryLayout.size(ofValue: config))

        let modelPath = (modelDir as NSString).appendingPathComponent("model.onnx")
        let tokensPath = (modelDir as NSString).appendingPathComponent("tokens.txt")

        // SenseVoice config — strdup returns UnsafeMutablePointer?, cast to UnsafePointer
        config.model_config.sense_voice.model = UnsafePointer(strdup(modelPath)!)
        config.model_config.sense_voice.language = UnsafePointer(strdup("auto")!)
        config.model_config.sense_voice.use_itn = 1
        config.model_config.tokens = UnsafePointer(strdup(tokensPath)!)
        config.model_config.num_threads = 2
        config.model_config.provider = UnsafePointer(strdup("cpu")!)
        config.model_config.debug = 0
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80

        offlineRecognizer = SherpaOnnxCreateOfflineRecognizer(&config)

        if offlineRecognizer == nil {
            print("SherpaRecognizer: Failed to create offline recognizer")
        }

        // Free strdup'd strings
        free(UnsafeMutablePointer(mutating: config.model_config.sense_voice.model))
        free(UnsafeMutablePointer(mutating: config.model_config.sense_voice.language))
        free(UnsafeMutablePointer(mutating: config.model_config.tokens))
        free(UnsafeMutablePointer(mutating: config.model_config.provider))
    }

    /// Run offline transcription on the full audio buffer.
    func transcribe(samples: [Float]) -> TranscriptResult {
        guard let recognizer = offlineRecognizer else {
            return TranscriptResult(text: "", language: nil)
        }

        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            return TranscriptResult(text: "", language: nil)
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        samples.withUnsafeBufferPointer { ptr in
            SherpaOnnxAcceptWaveformOffline(stream, 16000, ptr.baseAddress, Int32(samples.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let resultPtr = SherpaOnnxGetOfflineStreamResult(stream) else {
            return TranscriptResult(text: "", language: nil)
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(resultPtr) }

        let text = String(cString: resultPtr.pointee.text).trimmingCharacters(in: .whitespacesAndNewlines)
        let lang: String? = {
            guard let l = resultPtr.pointee.lang else { return nil }
            let s = String(cString: l)
            return s.isEmpty ? nil : s
        }()

        return TranscriptResult(text: text, language: lang)
    }

}
