import AppKit
import Foundation

/// A single alias mapping: wrong → right.
struct Alias: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var from: String
    var to: String

    enum CodingKeys: String, CodingKey {
        case from, to
    }

    init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.from = try c.decode(String.self, forKey: .from)
        self.to = try c.decode(String.self, forKey: .to)
    }
}

/// Unified vocabulary: priority terms + deterministic alias corrections.
struct Vocabulary: Codable, Equatable {
    var terms: [String]
    var aliases: [Alias]

    init(terms: [String] = [], aliases: [Alias] = []) {
        self.terms = terms
        self.aliases = aliases
    }
}

/// Manages ~/.voicepad/vocabulary.json — the unified replacement for
/// dictionary.txt and corrections.txt.
final class VocabularyStore {
    static let shared = VocabularyStore()

    private let filePath = ConfigDirectory.path + "/vocabulary.json"

    private init() {}

    // MARK: - Load / Save

    func load() -> Vocabulary {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            return Vocabulary()
        }
        do {
            return try JSONDecoder().decode(Vocabulary.self, from: data)
        } catch {
            vpLog("[VocabularyStore] JSON parse error: \(error)")
            return Vocabulary()
        }
    }

    func save(_ vocabulary: Vocabulary) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(vocabulary) else { return }
        ConfigDirectory.ensureExists()
        FileManager.default.createFile(atPath: filePath, contents: data)
        vpLog("[VocabularyStore] Saved \(vocabulary.terms.count) terms, \(vocabulary.aliases.count) aliases")
    }

    // MARK: - Counts (for menu display)

    var termCount: Int { load().terms.count }
    var aliasCount: Int { load().aliases.count }

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: filePath)
    }

    // MARK: - Alias Application

    /// Apply alias corrections using case-insensitive word-boundary matching.
    /// Preserves exact CorrectionEngine.apply() regex behavior.
    func applyAliases(_ text: String, aliases: [Alias]) -> String {
        var result = text
        for alias in aliases {
            let escaped = NSRegularExpression.escapedPattern(for: alias.from)
            let regexPattern = "\\b\(escaped)\\b"
            do {
                let regex = try NSRegularExpression(pattern: regexPattern, options: .caseInsensitive)
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: alias.to
                )
            } catch {
                vpLog("[VocabularyStore] Invalid regex for alias '\(alias.from)': \(error)")
            }
        }
        return result
    }

    // MARK: - Migration from old files

    /// Migrate dictionary.txt + corrections.txt → vocabulary.json on first launch.
    func migrateIfNeeded() {
        guard !fileExists else { return }

        let dictPath = ConfigDirectory.path + "/dictionary.txt"
        let corrPath = ConfigDirectory.path + "/corrections.txt"
        let fm = FileManager.default

        let hasDictionary = fm.fileExists(atPath: dictPath)
        let hasCorrections = fm.fileExists(atPath: corrPath)

        guard hasDictionary || hasCorrections else { return }

        vpLog("[VocabularyStore] Migrating old files...")

        var terms: [String] = []
        var aliases: [Alias] = []

        // Read dictionary.txt → terms
        if hasDictionary,
           let data = fm.contents(atPath: dictPath),
           let content = String(data: data, encoding: .utf8) {
            terms = content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }

        // Read corrections.txt → aliases
        if hasCorrections,
           let data = fm.contents(atPath: corrPath),
           let content = String(data: data, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                guard let separatorRange = trimmed.range(of: " -> ") else { continue }
                let from = String(trimmed[trimmed.startIndex..<separatorRange.lowerBound])
                let to = String(trimmed[separatorRange.upperBound...])
                guard !from.isEmpty else { continue }
                aliases.append(Alias(from: from, to: to))
            }
        }

        // Write vocabulary.json first (atomic step)
        let vocabulary = Vocabulary(terms: terms, aliases: aliases)
        save(vocabulary)

        // Then rename old files
        if hasDictionary {
            try? fm.moveItem(atPath: dictPath, toPath: dictPath + ".migrated")
        }
        if hasCorrections {
            try? fm.moveItem(atPath: corrPath, toPath: corrPath + ".migrated")
        }

        vpLog("[VocabularyStore] Migration complete: \(terms.count) terms, \(aliases.count) aliases")
    }
}
