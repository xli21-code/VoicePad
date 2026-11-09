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

        // Remove filler words (呃、嗯、uh、um, repeated phrases, etc.)
        result = removeFillerWords(result)

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

    // MARK: - Filler Word Removal

    private func removeFillerWords(_ text: String) -> String {
        var result = text

        // Regex patterns paired with their replacements.
        // Order matters: longer / more specific patterns first.
        let replacements: [(pattern: String, replacement: String)] = [
            // === Chinese fillers ===
            // 呃 — pure speech filler, no legitimate compound words
            (#"呃+"#, ""),
            // 额 — only remove repeated (single 额 has too many compounds: 名额/份额/税额...)
            (#"额{2,}"#, ""),
            // 嗯 — doesn't form compound words in Chinese; almost always filler in dictation
            (#"嗯+"#, ""),
            // 啊 — only remove repeated (single 啊 is often a meaningful sentence particle)
            (#"啊{3,}"#, "啊"),
            // 哦/噢 — repeated
            (#"[哦噢]{2,}"#, ""),
            // Repeated phrase fillers → collapse to one
            (#"(?:然后){2,}"#, "然后"),
            (#"(?:那个){2,}"#, "那个"),
            (#"(?:就是){2,}"#, "就是"),
            (#"(?:就是说){2,}"#, "就是说"),
            // Repeated agreement/filler → remove
            (#"对{3,}"#, ""),
            (#"(?:是的){2,}"#, ""),
            (#"(?:好的){2,}"#, ""),
            // === English fillers ===
            (#"\b[Uu]h+\b"#, ""),
            (#"\b[Uu]m+\b"#, ""),
        ]

        for (pattern, replacement) in replacements {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: replacement
                )
            }
        }

        // Clean up artifacts left by removal:
        // 1a. Collapse repeated same punctuation (e.g. ，，→ ，)
        if let regex = try? NSRegularExpression(pattern: #"([，。！？、,\.!\?;；：:])\1+"#) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }
        // 1b. Mixed adjacent punctuation: strong mark (。！？) wins over weak mark (，、;)
        //     e.g. 。，→ 。   ，。→ 。
        if let regex = try? NSRegularExpression(pattern: #"([。！？\.!\?])\s*[，、,;；：:]"#) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }
        if let regex = try? NSRegularExpression(pattern: #"[，、,;；：:]\s*([。！？\.!\?])"#) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }
        // 1c. Adjacent weak punctuation (e.g. ，、→ ，)
        if let regex = try? NSRegularExpression(pattern: #"([，,])\s*[、;；]"#) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }
        // 2. Remove punctuation at the very start (e.g. "，我觉得" after leading filler removed)
        if let regex = try? NSRegularExpression(pattern: #"^[，、,;；\s]+"#) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }
        // 3. Collapse multiple spaces
        if let regex = try? NSRegularExpression(pattern: #" {2,}"#) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - SenseVoice Tags

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
