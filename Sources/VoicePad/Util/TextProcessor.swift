import Foundation

/// Post-processes transcribed text: SenseVoice tag removal, deterministic corrections,
/// capitalization, punctuation cleanup.
struct TextProcessor {
    /// Process raw transcription output into clean text.
    /// Applies pre-LLM alias corrections. Post-LLM corrections are applied separately.
    func process(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // SenseVoice may include event/emotion tags like <|SPEECH|> — remove them
        result = removeSenseVoiceTags(result)

        // Capitalize first letter (for English text)
        result = capitalizeFirst(result)

        // Clean up spacing around punctuation
        result = cleanPunctuation(result)

        // Apply deterministic pre-corrections via vocabulary aliases
        let aliases = VocabularyStore.shared.load().aliases
        if !aliases.isEmpty {
            result = VocabularyStore.shared.applyAliases(result, aliases: aliases)
        }

        return result
    }

    /// Apply post-LLM corrections (re-apply aliases to catch LLM alterations).
    func applyPostCorrections(_ text: String) -> String {
        let aliases = VocabularyStore.shared.load().aliases
        guard !aliases.isEmpty else { return text }
        return VocabularyStore.shared.applyAliases(text, aliases: aliases)
    }

    private func removeSenseVoiceTags(_ text: String) -> String {
        var result = text

        // Remove tags like <|SPEECH|>, <|EMO_HAPPY|>, <|Event_BGM|>, <|NR|>, etc.
        let tagPattern = #"<\|[A-Za-z_]+\|>"#
        if let regex = try? NSRegularExpression(pattern: tagPattern) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Remove standalone noise markers that SenseVoice may output as plain text
        // (NR = noise/non-recognizable, [NR], (NR), etc.)
        let noisePattern = #"[\[\(（]?\b(?:NR|NOISE|BLANK)\b[\]\)）]?"#
        if let regex = try? NSRegularExpression(pattern: noisePattern, options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func capitalizeFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // Only capitalize if it starts with a Latin letter
        if first.isLetter && first.isASCII {
            return first.uppercased() + text.dropFirst()
        }
        return text
    }

    private func cleanPunctuation(_ text: String) -> String {
        var result = text

        // Remove spaces before punctuation
        result = result.replacingOccurrences(of: " ,", with: ",")
        result = result.replacingOccurrences(of: " .", with: ".")
        result = result.replacingOccurrences(of: " ?", with: "?")
        result = result.replacingOccurrences(of: " !", with: "!")
        result = result.replacingOccurrences(of: " ;", with: ";")
        result = result.replacingOccurrences(of: " :", with: ":")

        // Chinese punctuation
        result = result.replacingOccurrences(of: " ，", with: "，")
        result = result.replacingOccurrences(of: " 。", with: "。")
        result = result.replacingOccurrences(of: " ？", with: "？")
        result = result.replacingOccurrences(of: " ！", with: "！")

        return result
    }
}
