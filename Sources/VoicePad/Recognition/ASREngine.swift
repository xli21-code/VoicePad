import Foundation

/// A local speech recogniser. Engines are interchangeable: the pipeline runs one primary
/// engine and falls back to another when the primary is not ready or returns nothing.
protocol ASREngine: AnyObject {
    /// Shown in logs and in the recorded training pair, so we can tell which engine
    /// produced a transcript when comparing quality later.
    var name: String { get }
    var isReady: Bool { get }

    /// Transcribe 16 kHz mono samples. `prompt` biases spelling and style; engines
    /// without such a channel ignore it by design (see `SenseVoiceEngine`).
    func transcribe(samples: [Float], prompt: String?) async -> TranscriptResult?
}

/// Builds the initial prompt handed to Whisper.
///
/// Measured on 37 real dictations (Chinese with embedded English jargon), see
/// docs/eval-2026-11-09.md: a short style hint plus a term list lifts English-term
/// survival from 48% to 87% and removes traditional-character output. A longer
/// exemplar sentence looked tempting but cost accuracy (terms 71%, CER 18.5% vs 13.5%),
/// because Whisper's prompt is a style/spelling sample, not an instruction.
enum ASRPrompt {
    private static let style = "简体中文，标点完整。例如：你好，今天开会。"

    private static let baseTerms = [
        "VoicePad", "Magpie", "Qwen3-ASR", "SenseVoice", "sherpa-onnx", "CER",
        "benchmark", "drawdown", "hedge", "tail latency", "p50", "p90",
        "config schema", "prompt", "token", "API endpoint", "Deepgram",
    ]

    /// Whisper's prompt is capped (224 tokens); stay well inside it.
    private static let maxCharacters = 300

    static func build(vocabulary: [String] = []) -> String {
        var terms = baseTerms
        for term in vocabulary where term.containsLatinLetter {
            if !terms.contains(term) { terms.append(term) }
        }

        var prompt = style
        for term in terms {
            let candidate = prompt + term + ", "
            if candidate.count > maxCharacters { break }
            prompt = candidate
        }
        return prompt.trimmingCharacters(in: .whitespaces)
    }
}

private extension String {
    /// Only Latin-script terms are worth feeding back to the decoder; Chinese words are
    /// already handled by the acoustic model.
    var containsLatinLetter: Bool {
        unicodeScalars.contains { CharacterSet.letters.contains($0) && $0.isASCII }
    }
}

/// SenseVoice has no prompt/hotword channel: it always decodes the raw audio.
extension SherpaRecognizer: ASREngine {
    var name: String { "SenseVoice" }
    var isReady: Bool { true }

    func transcribe(samples: [Float], prompt: String?) async -> TranscriptResult? {
        let result = await Task.detached(priority: .userInitiated) { [self] in
            transcribe(samples: samples)
        }.value
        return result.text.isEmpty ? nil : result
    }
}
