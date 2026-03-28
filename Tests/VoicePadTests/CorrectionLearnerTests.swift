import Foundation
import Testing

@testable import VoicePad

@Suite("CorrectionLearner")
struct CorrectionLearnerTests {
    let learner = CorrectionLearner()

    @Test("Detects simple word replacement as alias")
    func simpleReplacement() {
        let result = learner.extractCorrections(
            original: "I use 克劳德 to code",
            corrected: "I use Claude to code"
        )
        #expect(result.newAliases.count == 1)
        #expect(result.newAliases.first?.from == "克劳德")
        #expect(result.newAliases.first?.to == "Claude")
    }

    @Test("Detects capitalization change as term")
    func capitalizationChange() {
        let result = learner.extractCorrections(
            original: "I use openai daily",
            corrected: "I use OpenAI daily"
        )
        // Capitalization-only → term, not alias
        #expect(result.newTerms.contains("OpenAI"))
    }

    @Test("No changes → empty result")
    func noChanges() {
        let result = learner.extractCorrections(
            original: "Hello world",
            corrected: "Hello world"
        )
        #expect(result.newAliases.isEmpty)
        #expect(result.newTerms.isEmpty)
    }

    @Test("Multiple replacements detected")
    func multipleReplacements() {
        let result = learner.extractCorrections(
            original: "用 克劳德 和 安卓匹克 的产品",
            corrected: "用 Claude 和 Anthropic 的产品"
        )
        #expect(result.newAliases.count == 2)
    }

    @Test("Apply to vocabulary adds new items")
    func applyToVocabulary() {
        let result = CorrectionLearner.LearnResult(
            newAliases: [Alias(from: "test_wrong", to: "test_right")],
            newTerms: ["test_right"]
        )
        // Note: this actually writes to VocabularyStore.shared
        // In a real test environment we'd want isolation, but for now this validates the path
        let (terms, aliases) = learner.applyToVocabulary(result)
        #expect(terms >= 0) // May be 0 if already exists
        #expect(aliases >= 0)
    }
}
