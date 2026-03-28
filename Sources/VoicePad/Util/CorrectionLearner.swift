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
    /// Extracts word-level diffs as potential aliases and terms.
    func extractCorrections(original: String, corrected: String) -> LearnResult {
        // Tokenize both strings into words, preserving order
        let originalWords = tokenize(original)
        let correctedWords = tokenize(corrected)

        // Use simple LCS-based diff to find changed segments
        let diffs = computeWordDiffs(from: originalWords, to: correctedWords)

        var newAliases: [Alias] = []
        var newTerms: [String] = []

        for diff in diffs {
            switch diff {
            case .replacement(let from, let to):
                // User replaced one word/phrase with another → alias candidate
                let fromText = from.joined(separator: " ")
                let toText = to.joined(separator: " ")
                guard !fromText.isEmpty, !toText.isEmpty else { continue }

                // Skip if it's just capitalization of the same word
                if fromText.lowercased() == toText.lowercased() {
                    // Pure capitalization fix → add as term (correct casing)
                    newTerms.append(toText)
                } else {
                    newAliases.append(Alias(from: fromText, to: toText))
                    // Also add the correct form as a term
                    newTerms.append(toText)
                }

            case .insertion(let words):
                // User added words — not a correction, skip
                _ = words

            case .deletion:
                // User deleted words — not useful for vocabulary
                break
            }
        }

        return LearnResult(newAliases: newAliases, newTerms: newTerms)
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
        // Split on whitespace and punctuation boundaries, keeping words
        var words: [String] = []
        var current = ""
        for char in text {
            if char.isWhitespace {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }

    // MARK: - Word-level Diff

    private enum WordDiff {
        case replacement(from: [String], to: [String])
        case insertion([String])
        case deletion([String])
    }

    /// Compute word-level diffs between two token arrays using LCS.
    private func computeWordDiffs(from original: [String], to corrected: [String]) -> [WordDiff] {
        let lcs = longestCommonSubsequence(original, corrected)
        var diffs: [WordDiff] = []

        var oi = 0, ci = 0, li = 0

        while oi < original.count || ci < corrected.count {
            if li < lcs.count {
                // Collect tokens before the next LCS match
                var deletedWords: [String] = []
                var insertedWords: [String] = []

                while oi < original.count && original[oi] != lcs[li] {
                    deletedWords.append(original[oi])
                    oi += 1
                }
                while ci < corrected.count && corrected[ci] != lcs[li] {
                    insertedWords.append(corrected[ci])
                    ci += 1
                }

                if !deletedWords.isEmpty && !insertedWords.isEmpty {
                    diffs.append(.replacement(from: deletedWords, to: insertedWords))
                } else if !deletedWords.isEmpty {
                    diffs.append(.deletion(deletedWords))
                } else if !insertedWords.isEmpty {
                    diffs.append(.insertion(insertedWords))
                }

                // Skip the matching LCS word
                oi += 1
                ci += 1
                li += 1
            } else {
                // Past the end of LCS — remaining tokens are changes
                var deletedWords: [String] = []
                var insertedWords: [String] = []
                while oi < original.count {
                    deletedWords.append(original[oi])
                    oi += 1
                }
                while ci < corrected.count {
                    insertedWords.append(corrected[ci])
                    ci += 1
                }
                if !deletedWords.isEmpty && !insertedWords.isEmpty {
                    diffs.append(.replacement(from: deletedWords, to: insertedWords))
                } else if !deletedWords.isEmpty {
                    diffs.append(.deletion(deletedWords))
                } else if !insertedWords.isEmpty {
                    diffs.append(.insertion(insertedWords))
                }
            }
        }

        return diffs
    }

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
