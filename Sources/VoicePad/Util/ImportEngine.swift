import Foundation

/// Portable bundle for export/import of all VoicePad intelligence data.
struct ExportBundle: Codable {
    let version: Int
    let vocabulary: Vocabulary
    let branches: [Branch]
    let exportedAt: Date

    init(vocabulary: Vocabulary, branches: [Branch]) {
        self.version = 1
        self.vocabulary = vocabulary
        self.branches = branches
        self.exportedAt = Date()
    }
}

/// Handles LLM-powered vocabulary import and structured export.
struct ImportEngine {

    /// Parse arbitrary text (word list, CSV, dictionary export) into Vocabulary
    /// using Claude to extract terms and aliases.
    func parseVocabulary(from text: String) async throws -> Vocabulary {
        let truncated = String(text.prefix(50 * 1024))

        let prompt = """
        Parse the following word list / dictionary export into a JSON object with this exact format:
        {"terms": ["word1", "word2"], "aliases": [{"from": "misspelling", "to": "correct"}]}

        Rules:
        - "terms" = correctly spelled words, proper nouns, technical terms, brand names
        - "aliases" = known misspelling/misrecognition → correct form mappings
        - If the input is a simple word list, put everything in "terms" with an empty aliases array
        - If the input has columns like "wrong/right" or "from/to", map those to aliases
        - Deduplicate terms
        - Return ONLY the JSON object, no explanation

        Input:
        \(truncated)
        """

        let response = try await LLMPolisher().call(prompt: prompt, maxTokens: 4096)

        // Extract JSON from response (LLM might wrap in markdown code block)
        let jsonString = extractJSON(from: response)

        guard let data = jsonString.data(using: .utf8) else {
            throw ImportError.parseError("Could not encode response as data")
        }

        do {
            return try JSONDecoder().decode(Vocabulary.self, from: data)
        } catch {
            throw ImportError.parseError("Could not parse LLM response as vocabulary: \(error.localizedDescription)")
        }
    }

    /// Export current vocabulary + branches as a portable bundle.
    func exportBundle() -> ExportBundle {
        let vocabulary = VocabularyStore.shared.load()
        let branches = AppBranchStore.shared.loadBranches()
        return ExportBundle(vocabulary: vocabulary, branches: branches)
    }

    /// Import from an ExportBundle, merging with existing data.
    func importBundle(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(ExportBundle.self, from: data)

        // Merge vocabulary
        var vocab = VocabularyStore.shared.load()
        vocab.terms.append(contentsOf: bundle.vocabulary.terms)
        vocab.terms = Array(Set(vocab.terms))
        vocab.aliases.append(contentsOf: bundle.vocabulary.aliases)
        VocabularyStore.shared.save(vocab)

        // Replace branches (import overwrites)
        AppBranchStore.shared.saveBranches(bundle.branches)
    }

    // MARK: - Helpers

    /// Extract JSON object from LLM response that might include markdown fencing.
    private func extractJSON(from text: String) -> String {
        // Try to find JSON between ```json ... ``` or ``` ... ```
        let patterns = [
            #"```json\s*\n([\s\S]*?)\n```"#,
            #"```\s*\n([\s\S]*?)\n```"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }
        // No fencing found — try the whole response
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ImportError: LocalizedError {
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .parseError(let msg): msg
        }
    }
}
