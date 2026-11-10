import Foundation
import Testing

@testable import VoicePad

@Suite("TextProcessor")
struct TextProcessorTests {

    private let processor = TextProcessor()

    // MARK: - Traditional → Simplified

    @Test("A whole utterance in traditional characters comes back simplified")
    func wholeUtteranceTraditional() {
        // The real failure from the 37-recording evaluation: Whisper ignored the
        // 简体中文 prompt and returned the sentence entirely in traditional characters.
        #expect(processor.process("這就先把這個定下來") == "这就先把这个定下来")
    }

    @Test("Stray traditional characters inside a simplified sentence are fixed")
    func strayTraditional() {
        #expect(processor.process("我們四月底已經減倉了") == "我们四月底已经减仓了")
    }

    @Test("English words and Latin punctuation survive the transform")
    func mixedLanguage() {
        let out = processor.process("The drawdown is mainly from the April correction，但是我們四月底已經減倉了")
        #expect(out.contains("The drawdown is mainly from the April correction"))
        #expect(out.contains("我们四月底已经减仓了"))
    }

    @Test("Simplified input is left byte-for-byte alone")
    func simplifiedUntouched() {
        let text = "我们四月底已经减仓了，回撤主要来自四月的调整"
        #expect(processor.process(text) == text)
    }

    @Test("Characters valid in both forms are not mangled")
    func sharedCharacters() {
        // 著 exists in simplified too (著名). A naive char map turns it into 着 and
        // corrupts the word; the ICU transform is phrase-aware.
        #expect(processor.process("著名") == "著名")
        #expect(processor.process("看著") == "看着")
    }

    @Test("Pure Latin text takes the fast path")
    func latinOnly() {
        // Only the pre-existing first-letter capitalisation applies; the Chinese transform
        // must not touch it.
        #expect(processor.process("the p50 latency is 698 milliseconds")
                == "The p50 latency is 698 milliseconds")
    }

    @Test("Digits, code identifiers and punctuation are preserved")
    func technicalTokens() {
        let out = processor.process("Qwen3-ASR 的 p50 是 698ms，Qwen3-ASR 沒問題")
        #expect(out.contains("Qwen3-ASR"))
        #expect(out.contains("698ms"))
        #expect(out.contains("没问题"))
    }
}
