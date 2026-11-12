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

    /// Whisper decodes 30 s at a time.
    static let windowSamples = 480_000
    /// ±3 s before the nominal boundary to look for a quiet cut point. Never after: a window
    /// longer than 30 s is truncated by the encoder and decodes to nothing.
    static let boundarySearch = 48_000
    /// Never emit a window shorter than 10 s: a stub window decodes to nothing.
    static let minWindowSamples = 160_000
    /// A window quieter than this carries no speech worth retrying.
    static let audibleRMS: Float = 0.005

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
        // Windowing is ours (see `windows(of:)`): WhisperKit's own VAD chunker drops a chunk
        // whose decode fails or comes back empty, without an error, which is exactly the
        // failure this code has to be able to see.
        options.chunkingStrategy = .none

        if let prompt, !prompt.isEmpty,
           let tokens = pipe.tokenizer?.encode(text: prompt), !tokens.isEmpty {
            options.promptTokens = tokens
        }

        let ranges = Self.windows(of: samples)
        let started = Date()
        var pieces: [String] = []

        for range in ranges {
            var text = await decodeWindow(pipe, samples: Array(samples[range]), options: options)
            if text.isEmpty, Self.rms(samples[range]) > Self.audibleRMS {
                // Whisper emits end-of-text immediately when a window opens on a hard edge —
                // same 10.3 s of audible speech measured 0 chars at 24.9 s and 48 chars at
                // 26.9 s in a real 35 s dictation. Moving the start forward recovers it.
                for shiftSeconds in [1, 2] where text.isEmpty {
                    let shiftedStart = range.lowerBound + shiftSeconds * 16000
                    guard shiftedStart < range.upperBound else { break }
                    text = await decodeWindow(pipe, samples: Array(samples[shiftedStart..<range.upperBound]),
                                              options: options)
                    if !text.isEmpty {
                        vpLog("[WhisperKitEngine] empty window at \(range.lowerBound / 16000)s,"
                              + " recovered at +\(shiftSeconds)s")
                    }
                }
            }
            pieces.append(text)
        }

        let ms = Int(Date().timeIntervalSince(started) * 1000)
        vpLog("[WhisperKitEngine] decode \(ms)ms for \(String(format: "%.1f", Double(samples.count) / 16000))s audio"
              + " in \(ranges.count) window(s)")
        let text = pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return TranscriptResult(text: text, language: "zh")
    }

    private func decodeWindow(_ pipe: WhisperKit, samples: [Float], options: DecodingOptions) async -> String {
        do {
            let results = try await pipe.transcribe(audioArray: samples, audioArrayOffset: 0, decodeOptions: options)
            return results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            vpLog("[WhisperKitEngine] window decode failed: \(error)")
            return ""
        }
    }

    // MARK: - Windowing

    /// Cut points for audio longer than one Whisper window, chosen at the quietest point
    /// near each 30 s boundary so a window does not open mid-word. The ranges tile the whole
    /// recording: no samples are dropped, which is what makes a missing tail impossible.
    static func windows(of samples: [Float]) -> [Range<Int>] {
        guard !samples.isEmpty else { return [] }
        guard samples.count > windowSamples else { return [0..<samples.count] }

        var result: [Range<Int>] = []
        var start = 0
        while start < samples.count {
            let nominalEnd = start + windowSamples
            guard nominalEnd < samples.count else {
                result.append(start..<samples.count)
                break
            }
            // Cut at or before the nominal boundary: a window longer than Whisper's own
            // 30 s window gets truncated by the encoder and comes back empty.
            let low = max(start + minWindowSamples, nominalEnd - boundarySearch)
            let high = min(samples.count - 1, nominalEnd)
            let cut = low >= high ? nominalEnd : quietestCut(in: samples, from: low, to: high)
            result.append(start..<cut)
            start = cut
        }
        return result
    }

    /// Index of the quietest 20 ms hop in `low..<high`.
    static func quietestCut(in samples: [Float], from low: Int, to high: Int) -> Int {
        let hop = 320                      // 20 ms at 16 kHz
        let end = min(high, samples.count)
        var bestIndex = min(end, samples.count)
        var bestEnergy = Float.greatestFiniteMagnitude
        var i = max(0, low)
        while i + hop <= end {
            var energy: Float = 0
            for j in i..<(i + hop) { energy += samples[j] * samples[j] }
            if energy < bestEnergy {
                bestEnergy = energy
                bestIndex = i + hop / 2
            }
            i += hop
        }
        return bestIndex
    }

    static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }
}
