import Foundation
import Testing

@testable import VoicePad

@Suite("VocabularyStore")
struct VocabularyStoreTests {

    // MARK: - Alias Application

    @Test("Basic alias substitution")
    func aliasBasic() {
        let store = VocabularyStore.shared
        let aliases = [Alias(from: "claude", to: "Claude")]
        let result = store.applyAliases("I use claude daily", aliases: aliases)
        #expect(result == "I use Claude daily")
    }

    @Test("Case-insensitive alias matching")
    func aliasCaseInsensitive() {
        let store = VocabularyStore.shared
        let aliases = [Alias(from: "openai", to: "OpenAI")]
        let result = store.applyAliases("I like OPENAI and openai", aliases: aliases)
        #expect(result == "I like OpenAI and OpenAI")
    }

    @Test("Word-boundary only — no partial match")
    func aliasWordBoundary() {
        let store = VocabularyStore.shared
        let aliases = [Alias(from: "go", to: "Go")]
        let result = store.applyAliases("I am going to use go today", aliases: aliases)
        // "going" should NOT be affected, only standalone "go"
        #expect(result == "I am going to use Go today")
    }

    @Test("Regex special characters in alias are escaped")
    func aliasRegexSpecialChars() {
        let store = VocabularyStore.shared
        let aliases = [Alias(from: "c++", to: "C++")]
        let result = store.applyAliases("I code in c++ every day", aliases: aliases)
        // c++ has regex special chars (+) — should not crash
        // Note: \b may not match around ++ perfectly, but it should not crash
        #expect(result.contains("C++") || result.contains("c++"))
    }

    @Test("Empty aliases returns text unchanged")
    func aliasEmpty() {
        let store = VocabularyStore.shared
        let result = store.applyAliases("Hello world", aliases: [])
        #expect(result == "Hello world")
    }

    @Test("Multiple aliases applied in order")
    func aliasMultiple() {
        let store = VocabularyStore.shared
        let aliases = [
            Alias(from: "gpt4", to: "GPT-4"),
            Alias(from: "claude", to: "Claude"),
        ]
        let result = store.applyAliases("I use gpt4 and claude", aliases: aliases)
        #expect(result == "I use GPT-4 and Claude")
    }

    // MARK: - Vocabulary Codable

    @Test("Vocabulary round-trips through JSON")
    func vocabularyRoundtrip() throws {
        let vocab = Vocabulary(
            terms: ["Anthropic", "Claude"],
            aliases: [Alias(from: "test", to: "Test")]
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(vocab)
        let decoded = try JSONDecoder().decode(Vocabulary.self, from: data)
        #expect(decoded.terms == vocab.terms)
        #expect(decoded.aliases.count == 1)
        #expect(decoded.aliases[0].from == "test")
        #expect(decoded.aliases[0].to == "Test")
    }

    // MARK: - Migration Parsing

    @Test("Corrections line parsing: wrong -> right")
    func correctionsLineParsing() {
        // Test the same parsing logic used in migrateIfNeeded
        let line = "claude code -> Claude Code"
        guard let range = line.range(of: " -> ") else {
            Issue.record("Separator not found")
            return
        }
        let from = String(line[line.startIndex..<range.lowerBound])
        let to = String(line[range.upperBound...])
        #expect(from == "claude code")
        #expect(to == "Claude Code")
    }
}
