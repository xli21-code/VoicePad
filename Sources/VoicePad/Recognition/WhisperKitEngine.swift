import Foundation
import WhisperKit

/// Whisper large-v3-turbo via WhisperKit (Core ML / ANE).
///
/// Chosen as the primary engine because the term prompt in `ASRPrompt` fixes the failure
/// that hurt most: English jargon inside Chinese sentences (VoicePad, Magpie, CER…).
/// See docs/eval-2026-11-09.md for the measurements behind this choice.
///
/// Model download (~1.5 GB) happens on first launch; until it finishes `isReady` is false
/// and the pipeline falls back to SenseVoice, so dictation keeps working.
final class WhisperKitEngine: ASREngine {
    static let variant = "large-v3-v20240930_turbo"

    private var pipe: WhisperKit?
    private var preparing = false
    private(set) var loadError: String?

    var name: String { "Whisper turbo" }
    var isReady: Bool { pipe != nil }

    private var downloadBase: URL {
        URL(fileURLWithPath: ConfigDirectory.path + "/models/whisperkit")
    }

    /// An already-downloaded model folder, if one exists. Avoids a network round-trip
    /// (and a 1.5 GB re-download) on every launch and during offline use.
    private var localModelFolder: URL? {
        let folder = downloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(Self.variant)")
        let marker = folder.appendingPathComponent("TextDecoder.mlmodelc").path
        return FileManager.default.fileExists(atPath: marker) ? folder : nil
    }

    /// Tokenizer files live next to the model in the Hub cache layout.
    private var localTokenizerFolder: URL? {
        let folder = downloadBase.appendingPathComponent("models/openai/whisper-large-v3")
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path)
            ? folder : nil
    }

    /// Loads off the main thread: CoreML model compilation and ANE prewarm must not
    /// run on the main actor, otherwise the app beachballs while it is preparing.
    func prepare() async {
        await Task.detached(priority: .utility) { [self] in
            await prepareOffMain()
        }.value
    }

    private func prepareOffMain() async {
        guard pipe == nil, !preparing else { return }
        preparing = true
        defer { preparing = false }
        vpLog("[WhisperKitEngine] loading \(Self.variant)...")

        do {
            let folder: URL
            if let localModelFolder {
                folder = localModelFolder
                vpLog("[WhisperKitEngine] using local model at \(folder.path)")
            } else {
                folder = try await downloadModel()
            }
            // Compute placement was measured on this machine (M4 Pro, macOS 26.6):
            // - encoder on ANE hangs inside CoreML's loader (125 s, then never returns)
            // - decoder on ANE is fine and ~25% faster than GPU (1.22 s vs 1.62 s per clip)
            // so: encoder stays on GPU, decoder goes to ANE.
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                tokenizerFolder: localTokenizerFolder,
                computeOptions: ModelComputeOptions(
                    melCompute: .cpuAndGPU,
                    audioEncoderCompute: .cpuAndGPU,
                    textDecoderCompute: .cpuAndNeuralEngine
                ),
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false
            )
            let loaded = try await WhisperKit(config)
            pipe = loaded
            await warmUpDecode(with: loaded)
            vpLog("[WhisperKitEngine] ready: \(Self.variant)")
        } catch {
            loadError = error.localizedDescription
            vpLog("[WhisperKitEngine] load failed: \(error)")
        }
    }

    /// The first real decode after loading pays a ~3 s graph-specialisation cost, which
    /// lands exactly on the user's first dictation. Burn it here on silence instead.
    private func warmUpDecode(with pipe: WhisperKit) async {
        let silence = [Float](repeating: 0, count: 16000 * 3)
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = "zh"
        options.temperature = 0
        options.withoutTimestamps = true
        options.skipSpecialTokens = true
        // Without this, Whisper treats silence as "no speech" and returns in 3 ms,
        // which warms nothing. The transcript is thrown away.
        options.noSpeechThreshold = 0
        let started = Date()
        _ = try? await pipe.transcribe(audioArray: silence, audioArrayOffset: 0, decodeOptions: options)
        vpLog("[WhisperKitEngine] warm-up decode \(Int(Date().timeIntervalSince(started) * 1000))ms")
    }

    private func downloadModel() async throws -> URL {
        try await WhisperKit.download(variant: Self.variant, downloadBase: downloadBase) { progress in
                let pct = Int(progress.fractionCompleted * 100)
                if pct % 10 == 0 {
                    vpLog("[WhisperKitEngine] model download \(pct)%")
                }
        }
    }

    func transcribe(samples: [Float], prompt: String?) async -> TranscriptResult? {
        await Task.detached(priority: .userInitiated) { [self] in
            await decode(samples: samples, prompt: prompt)
        }.value
    }

    private func decode(samples: [Float], prompt: String?) async -> TranscriptResult? {
        guard let pipe, !samples.isEmpty else { return nil }

        var options = DecodingOptions()
        options.task = .transcribe
        options.language = "zh"
        options.temperature = 0
        options.withoutTimestamps = true
        options.skipSpecialTokens = true
        options.chunkingStrategy = .vad

        if let prompt, !prompt.isEmpty,
           let tokens = pipe.tokenizer?.encode(text: prompt), !tokens.isEmpty {
            options.promptTokens = tokens
        }

        do {
            let started = Date()
            let results = try await pipe.transcribe(
                audioArray: samples,
                audioArrayOffset: 0,
                decodeOptions: options
            )
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            vpLog("[WhisperKitEngine] decode \(ms)ms for \(String(format: "%.1f", Double(samples.count) / 16000))s audio")
            let text = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptResult(text: text, language: "zh")
        } catch {
            vpLog("[WhisperKitEngine] transcribe failed: \(error)")
            return nil
        }
    }
}
