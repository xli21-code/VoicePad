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
            // ANE (the WhisperKit default on macOS) hung inside CoreML's model loader on
            // this machine — idle CPU, no progress for minutes. GPU loads in seconds, so we
            // pin it explicitly instead of relying on the default compute placement.
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                tokenizerFolder: localTokenizerFolder,
                computeOptions: ModelComputeOptions(
                    melCompute: .cpuAndGPU,
                    audioEncoderCompute: .cpuAndGPU,
                    textDecoderCompute: .cpuAndGPU
                ),
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false
            )
            pipe = try await WhisperKit(config)
            vpLog("[WhisperKitEngine] ready: \(Self.variant)")
        } catch {
            loadError = error.localizedDescription
            vpLog("[WhisperKitEngine] load failed: \(error)")
        }
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
            let results = try await pipe.transcribe(
                audioArray: samples,
                audioArrayOffset: 0,
                decodeOptions: options
            )
            let text = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptResult(text: text, language: "zh")
        } catch {
            vpLog("[WhisperKitEngine] transcribe failed: \(error)")
            return nil
        }
    }
}
