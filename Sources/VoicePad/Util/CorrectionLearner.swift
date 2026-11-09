import AppKit
import Foundation

/// Learns vocabulary corrections by comparing VoicePad's output with the user's edits.
///
/// Two modes:
/// 1. **Live readback**: Reads the current text from the frontmost app's focused text field
///    via Accessibility API, diffs against what VoicePad pasted, extracts changed words as aliases.
/// 2. **History diff**: Compares an edited transcript against the original to extract aliases.
struct CorrectionLearner {

    /// Result of a learn operation.
    struct LearnResult {
        let newAliases: [Alias]
        let newTerms: [String]
    }

    // MARK: - Accessibility Readback

    /// Read the current text content from the frontmost app's focused text field.
    /// Returns nil if Accessibility API can't read the field.
    func readFocusedTextField() -> String? {
        guard AXIsProcessTrusted() else {
            vpLog("[CorrectionLearner] Accessibility not trusted")
            return nil
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            vpLog("[CorrectionLearner] No frontmost app")
            return nil
        }

        let appRef = AXUIElementCreateApplication(frontApp.processIdentifier)

        // Get the focused UI element
        var focusedElement: CFTypeRef?
        let focusResult = AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusResult == .success, let element = focusedElement else {
            vpLog("[CorrectionLearner] Could not get focused element: \(focusResult.rawValue)")
            return nil
        }

        let axElement = element as! AXUIElement

        // Try to read the value (text content)
        var value: CFTypeRef?
        let valueResult = AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &value)
        guard valueResult == .success, let textValue = value as? String else {
            vpLog("[CorrectionLearner] Could not read text value: \(valueResult.rawValue)")
            return nil
        }

        return textValue
    }

    // MARK: - Diff & Learn

    /// Compare original (what VoicePad pasted) with corrected (what user changed it to).
    /// Extracts word-level replacements as aliases. For CJK text, single-character changes
    /// are expanded with adjacent context to form word-level aliases (e.g. 竞→尽 becomes 竞调→尽调).
    func extractCorrections(original: String, corrected: String) -> LearnResult {
        let originalTokens = tokenize(original)
        let correctedTokens = tokenize(corrected)
        let lcs = longestCommonSubsequence(originalTokens, correctedTokens)

        // Collect diffs with surrounding LCS context for CJK expansion
        struct RawDiff {
            let from: [String]
            let to: [String]
            let prevLCS: String?
            let nextLCS: String?
        }

        var rawDiffs: [RawDiff] = []
        var oi = 0, ci = 0, li = 0
        var prevLCS: String? = nil

        while oi < originalTokens.count || ci < correctedTokens.count {
            if li < lcs.count {
                var del: [String] = []
                var ins: [String] = []
                while oi < originalTokens.count && originalTokens[oi] != lcs[li] {
                    del.append(originalTokens[oi]); oi += 1
                }
                while ci < correctedTokens.count && correctedTokens[ci] != lcs[li] {
                    ins.append(correctedTokens[ci]); ci += 1
                }
                if !del.isEmpty && !ins.isEmpty {
                    rawDiffs.append(RawDiff(from: del, to: ins, prevLCS: prevLCS, nextLCS: lcs[li]))
                }
                prevLCS = lcs[li]
                oi += 1; ci += 1; li += 1
            } else {
                var del: [String] = []
                var ins: [String] = []
                while oi < originalTokens.count { del.append(originalTokens[oi]); oi += 1 }
                while ci < correctedTokens.count { ins.append(correctedTokens[ci]); ci += 1 }
                if !del.isEmpty && !ins.isEmpty {
                    rawDiffs.append(RawDiff(from: del, to: ins, prevLCS: prevLCS, nextLCS: nil))
                }
            }
        }

        // Build aliases, expanding single CJK char changes to word-level
        var newAliases: [Alias] = []

        for diff in rawDiffs {
            var fromTokens = diff.from
            var toTokens = diff.to

            // Single CJK character swapped for another → expand to 2-char word.
            // Prefer backward (深[调→度] → 深调→深度) but skip function words (的/了/和...).
            // Fallback to forward ([竞→尽]调 → 竞调→尽调).
            if fromTokens.count == 1 && toTokens.count == 1
                && fromTokens[0].count == 1 && toTokens[0].count == 1
                && fromTokens[0].first.map(isCJK) == true
                && toTokens[0].first.map(isCJK) == true {
                if let prev = diff.prevLCS, isContentCJK(prev) {
                    fromTokens.insert(prev, at: 0)
                    toTokens.insert(prev, at: 0)
                } else if let next = diff.nextLCS, isContentCJK(next) {
                    fromTokens.append(next)
                    toTokens.append(next)
                }
            }

            let fromText = joinTokens(fromTokens)
            let toText = joinTokens(toTokens)
            guard !fromText.isEmpty, !toText.isEmpty else { continue }
            if fromText.lowercased() == toText.lowercased() { continue }
            if fromTokens.count > 8 || toTokens.count > 8 { continue }

            newAliases.append(Alias(from: fromText, to: toText))
        }

        return LearnResult(newAliases: newAliases, newTerms: [])
    }

    /// Apply learned corrections to the vocabulary store.
    /// Returns the number of new items added.
    @discardableResult
    func applyToVocabulary(_ result: LearnResult) -> (terms: Int, aliases: Int) {
        guard !result.newAliases.isEmpty || !result.newTerms.isEmpty else { return (0, 0) }

        var vocab = VocabularyStore.shared.load()
        var addedTerms = 0
        var addedAliases = 0

        // Add new terms (deduplicate)
        for term in result.newTerms {
            if !vocab.terms.contains(term) {
                vocab.terms.append(term)
                addedTerms += 1
            }
        }

        // Add new aliases (check for duplicates by from+to)
        for alias in result.newAliases {
            let exists = vocab.aliases.contains { $0.from.lowercased() == alias.from.lowercased() && $0.to == alias.to }
            if !exists {
                vocab.aliases.append(alias)
                addedAliases += 1
            }
        }

        if addedTerms > 0 || addedAliases > 0 {
            VocabularyStore.shared.save(vocab)
            vpLog("[CorrectionLearner] Learned \(addedTerms) terms, \(addedAliases) aliases")
        }

        return (addedTerms, addedAliases)
    }

    // MARK: - Tokenizer

    private func tokenize(_ text: String) -> [String] {
        // Split on whitespace for Latin text, and split CJK characters individually
        // so that a single Chinese character change doesn't produce a whole-sentence alias.
        var tokens: [String] = []
        var latinBuffer = ""

        for char in text {
            if char.isWhitespace {
                if !latinBuffer.isEmpty {
                    tokens.append(latinBuffer)
                    latinBuffer = ""
                }
            } else if isCJK(char) {
                // Flush any Latin buffer first
                if !latinBuffer.isEmpty {
                    tokens.append(latinBuffer)
                    latinBuffer = ""
                }
                // Each CJK character is its own token
                tokens.append(String(char))
            } else {
                latinBuffer.append(char)
            }
        }
        if !latinBuffer.isEmpty {
            tokens.append(latinBuffer)
        }
        return tokens
    }

    /// Whether a token is a single CJK content character (not a common function word).
    /// Used to decide if a character is worth including when expanding aliases.
    private func isContentCJK(_ token: String) -> Bool {
        guard token.count == 1, let char = token.first, isCJK(char) else { return false }
        // Common function words / particles / pronouns — poor word-boundary markers
        let stopChars: Set<Character> = [
            "的", "了", "在", "是", "和", "或", "也", "都", "就", "会", "把", "被",
            "让", "给", "对", "向", "从", "到", "而", "但", "却", "又", "还", "才",
            "只", "很", "更", "最", "不", "没", "这", "那", "我", "你", "他", "她",
            "它", "们", "有", "为", "以", "及", "与", "于", "之", "所", "做", "去",
            "来", "上", "下", "中", "里", "用", "着", "过", "要", "能", "可", "得",
        ]
        return !stopChars.contains(char)
    }

    /// Check if a character is CJK (Chinese/Japanese/Korean).
    private func isCJK(_ char: Character) -> Bool {
        guard let scalar = char.unicodeScalars.first else { return false }
        let v = scalar.value
        // CJK Unified Ideographs + Extension A/B + Compatibility
        return (v >= 0x4E00 && v <= 0x9FFF)
            || (v >= 0x3400 && v <= 0x4DBF)
            || (v >= 0x20000 && v <= 0x2A6DF)
            || (v >= 0xF900 && v <= 0xFAFF)
            // CJK punctuation
            || (v >= 0x3000 && v <= 0x303F)
            // Fullwidth forms
            || (v >= 0xFF00 && v <= 0xFFEF)
    }

    /// Join tokens back into text, using no separator for CJK-only sequences.
    private func joinTokens(_ tokens: [String]) -> String {
        // If all tokens are single CJK characters, join without spaces
        let allCJK = tokens.allSatisfy { $0.count == 1 && $0.first.map(isCJK) == true }
        return tokens.joined(separator: allCJK ? "" : " ")
    }

    // MARK: - LCS

    /// Standard LCS algorithm on word arrays.
    private func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count, n = b.count
        guard m > 0, n > 0 else { return [] }

        // Build DP table
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to find the subsequence
        var result: [String] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                result.append(a[i - 1])
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }

        return result.reversed()
    }
}
