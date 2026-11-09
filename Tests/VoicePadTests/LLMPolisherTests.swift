import Foundation
import Testing

@testable import VoicePad

@Suite("LLMPolisher")
struct LLMPolisherTests {

    // MARK: - Config resolution

    @Test("Legacy config keys are read unchanged")
    func legacyConfigKeys() {
        let json: [String: Any] = [
            "anthropic_api_key": "sk-legacy",
            "api_base_url": "https://api.anthropic.com/",
            "model": "claude-sonnet-4-5-20241022",
        ]

        let config = VoicePadConfig.resolve(json: json)

        #expect(config.apiKey == "sk-legacy")
        #expect(config.baseURL == "https://api.anthropic.com")
        #expect(config.model == "claude-sonnet-4-5-20241022")
        #expect(config.translateModel == "claude-sonnet-4-5-20241022")
        #expect(config.importModel == "claude-sonnet-4-5-20241022")
    }

    @Test("V2 provider and models keys override legacy keys")
    func v2KeysOverrideLegacy() {
        let json: [String: Any] = [
            "anthropic_api_key": "sk-legacy",
            "api_base_url": "https://api.anthropic.com",
            "model": "claude-sonnet-4-5-20241022",
            "provider": [
                "base_url": "http://127.0.0.1:3425",
                "api_key": "magpie",
            ],
            "models": [
                "polish": "local/polish",
                "translate": "local/translate",
                "import": "local/import",
            ],
        ]

        let config = VoicePadConfig.resolve(json: json)

        #expect(config.apiKey == "magpie")
        #expect(config.baseURL == "http://127.0.0.1:3425")
        #expect(config.model == "local/polish")
        #expect(config.translateModel == "local/translate")
        #expect(config.importModel == "local/import")
    }

    @Test("Import model falls back to polish model")
    func importModelFallsBackToPolish() {
        let json: [String: Any] = [
            "models": ["polish": "local/polish"],
        ]

        let config = VoicePadConfig.resolve(json: json)

        #expect(config.translateModel == VoicePadConfig.defaultModel)
        #expect(config.importModel == "local/polish")
    }

    // MARK: - Local gateway key handling

    @Test("Local hosts are recognized")
    func localHostDetection() {
        #expect(VoicePadConfig.isLocalHost("http://127.0.0.1:3425"))
        #expect(VoicePadConfig.isLocalHost("http://localhost:3425/v1"))
        #expect(VoicePadConfig.isLocalHost("http://[::1]:3425"))
        #expect(!VoicePadConfig.isLocalHost("https://api.anthropic.com"))
        #expect(!VoicePadConfig.isLocalHost("http://192.168.1.10:3425"))
    }

    @Test("Local base URL works without an API key")
    func localAcceptsEmptyKey() {
        let json: [String: Any] = [
            "provider": ["base_url": "http://127.0.0.1:3425"],
        ]

        let config = VoicePadConfig.resolve(json: json)

        #expect(config.apiKey == nil)
        #expect(config.effectiveAPIKey == "")
    }

    @Test("Remote base URL still requires an API key")
    func remoteRequiresKey() {
        let json: [String: Any] = [
            "provider": ["base_url": "https://api.example.com"],
        ]

        let config = VoicePadConfig.resolve(json: json)

        #expect(config.effectiveAPIKey == nil)
    }

    // MARK: - Output sanity check

    @Test("Empty and whitespace-only output is rejected")
    func emptyOutputRejected() {
        #expect(!LLMPolisher.isUsableOutput("", for: "This is the spoken input."))
        #expect(!LLMPolisher.isUsableOutput("  \n\t ", for: "This is the spoken input."))
    }

    @Test("Too-short output is rejected")
    func shortOutputRejected() {
        let input = String(repeating: "a", count: 100)
        let tooShort = String(repeating: "b", count: 29)
        #expect(!LLMPolisher.isUsableOutput(tooShort, for: input))
    }

    @Test("Prompt→answer calls are not judged by length ratio")
    func promptAnswerNotRatioJudged() {
        // Vocabulary import: a long prompt legitimately produces a short answer.
        let prompt = String(repeating: "instruction ", count: 200)
        #expect(LLMPolisher.isUsableOutput("[]", for: prompt, checkLength: false))
        #expect(!LLMPolisher.isUsableOutput("", for: prompt, checkLength: false))
        // The same answer would be rejected when it is a rewrite of short input.
        #expect(!LLMPolisher.isUsableOutput("[]", for: "这句话需要整理", checkLength: true))
    }

    @Test("Normal rewrite is accepted")
    func normalRewriteAccepted() {
        let input = "um so this is the thing that I actually wanted to say about the API gateway"
        let output = "This is what I wanted to say about the API gateway."
        #expect(LLMPolisher.isUsableOutput(output, for: input))
    }
}
