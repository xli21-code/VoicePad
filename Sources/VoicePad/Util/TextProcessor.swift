import Foundation

/// Post-processes transcribed text: capitalization, punctuation, cleanup.
struct TextProcessor {
    /// Process raw transcription output into clean text.
    func process(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // SenseVoice may include event/emotion tags like <|SPEECH|> — remove them
        result = removeSenseVoiceTags(result)

        // Capitalize first letter (for English text)
        result = capitalizeFirst(result)

        // Clean up spacing around punctuation
        result = cleanPunctuation(result)

        return result
    }

    private func removeSenseVoiceTags(_ text: String) -> String {
        // Remove tags like <|SPEECH|>, <|EMO_HAPPY|>, <|Event_BGM|>, etc.
        var result = text
        let pattern = #"<\|[A-Z_]+\|>"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
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
