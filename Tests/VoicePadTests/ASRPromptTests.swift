import Foundation
import Testing

@testable import VoicePad

@Suite("ASRPrompt")
struct ASRPromptTests {
    @Test("Starts with the simplified-Chinese punctuation hint")
    func startsWithStyleHint() {
        let prompt = ASRPrompt.build()
        #expect(prompt.hasPrefix("简体中文，标点完整"))
    }

    @Test("Includes the domain terms that broke without a prompt")
    func includesBaseTerms() {
        let prompt = ASRPrompt.build()
        for term in ["VoicePad", "Magpie", "Qwen3-ASR", "CER", "tail latency"] {
            #expect(prompt.contains(term))
        }
    }

    @Test("Adds Latin vocabulary terms and skips Chinese-only ones")
    func mergesVocabulary() {
        let prompt = ASRPrompt.build(vocabulary: ["盛冠达", "OpenAI", "火富牛"])
        #expect(prompt.contains("OpenAI"))
        #expect(!prompt.contains("盛冠达"))
    }

    @Test("Stays inside Whisper's prompt budget")
    func respectsLengthCap() {
        let huge = (0..<200).map { "term\($0)" }
        let prompt = ASRPrompt.build(vocabulary: huge)
        #expect(prompt.count <= 320)
    }

    @Test("Does not duplicate a term already in the base list")
    func noDuplicates() {
        let prompt = ASRPrompt.build(vocabulary: ["Magpie"])
        let occurrences = prompt.components(separatedBy: "Magpie").count - 1
        #expect(occurrences == 1)
    }
}
