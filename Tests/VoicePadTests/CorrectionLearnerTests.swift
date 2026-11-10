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

    @Test("Capitalization-only change is skipped")
    func capitalizationChange() {
        let result = learner.extractCorrections(
            original: "I use openai daily",
            corrected: "I use OpenAI daily"
        )
        // Capitalization-only → skipped entirely (no alias, no term)
        #expect(result.newAliases.isEmpty)
        #expect(result.newTerms.isEmpty)
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

    @Test("Single CJK character change expands to a word using next context")
    func cjkExpansionForward() {
        // "做" is a stop word, so expansion falls forward to 调 → 竞调/尽调
        let result = learner.extractCorrections(
            original: "我们去做竞调",
            corrected: "我们去做尽调"
        )
        #expect(result.newAliases.count == 1)
        #expect(result.newAliases.first?.from == "竞调")
        #expect(result.newAliases.first?.to == "尽调")
    }

    @Test("A correction inside a long sentence is narrowed to the word")
    func narrowsToWord() {
        let original = "其他里面我都觉得没什么问题。就是我们刚刚说的，像蒙字那边的这个仲裁，我觉得可以定下来。"
        let corrected = "其他里面我都觉得没什么问题。就是我们刚刚说的，像蒙自那边的这个仲裁，我觉得可以定下来。"

        let result = learner.extractCorrections(original: original, corrected: corrected)

        #expect(result.newAliases.count == 1)
        #expect(result.newAliases.first?.from == "蒙字")
        #expect(result.newAliases.first?.to == "蒙自")
    }

    @Test("A lone CJK character with no word to anchor it is not learned")
    func unanchoredCharacterIsSkipped() {
        // 就 is a function word and the comma is punctuation, so nothing can anchor 退.
        // Learning 退→推 would rewrite 后退, 退休 and every other 退 in every dictation.
        let result = learner.extractCorrections(
            original: "你就搂一眼，有合适的就退，没合适的就算。",
            corrected: "你就搂一眼，有合适的就推，没合适的就算。"
        )
        #expect(result.newAliases.isEmpty)
    }

    @Test("A punctuation-only edit is not a correction")
    func punctuationOnlyChange() {
        let result = learner.extractCorrections(
            original: "我们明天出发，你看行不行",
            corrected: "我们明天出发。你看行不行"
        )
        #expect(result.newAliases.isEmpty)
    }
}
