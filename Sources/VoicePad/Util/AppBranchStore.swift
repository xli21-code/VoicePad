import AppKit
import Foundation

/// Built-in style presets for App Branch context.
enum BranchStyle: String, Codable, CaseIterable, Identifiable {
    case coding
    case chat
    case formal
    case academic
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .coding: "Coding"
        case .chat: "Chat"
        case .formal: "Formal"
        case .academic: "Academic"
        case .custom: "Custom"
        }
    }

    var builtInPrompt: String {
        switch self {
        case .coding:
            "保留代码术语、变量名、函数名原样。技术文档风格，简洁精确。"
        case .chat:
            "口语化，轻松自然，保留语气词。可以用缩写和网络用语。"
        case .formal:
            "正式商务语气，清晰简洁。适当使用敬语。"
        case .academic:
            "学术写作风格，严谨准确，使用专业术语。"
        case .custom:
            ""
        }
    }
}

/// An app context branch: maps frontmost apps to a style/prompt.
struct Branch: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var bundleIDs: [String]
    var style: BranchStyle
    var customPrompt: String?

    /// The effective prompt for this branch.
    var stylePrompt: String {
        switch style {
        case .custom: customPrompt ?? ""
        default: style.builtInPrompt
        }
    }

    init(id: UUID = UUID(), name: String, bundleIDs: [String], style: BranchStyle, customPrompt: String? = nil) {
        self.id = id
        self.name = name
        self.bundleIDs = bundleIDs
        self.style = style
        self.customPrompt = customPrompt
    }
}

/// Manages App Branch context awareness via ~/.voicepad/app-branches.json.
/// Maps frontmost app bundle IDs to specialized LLM prompts.
final class AppBranchStore {
    static let shared = AppBranchStore()

    private let filePath = ConfigDirectory.path + "/app-branches.json"

    private init() {}

    /// Load branch groups from app-branches.json.
    /// Handles both old format (prompt string) and new format (style enum).
    func loadBranches() -> [Branch] {
        guard let data = FileManager.default.contents(atPath: filePath) else {
            return []
        }

        // Try new format first
        if let branches = try? JSONDecoder().decode([Branch].self, from: data) {
            return branches
        }

        // Fall back to old format migration
        if let oldBranches = try? JSONDecoder().decode([OldBranch].self, from: data) {
            vpLog("[AppBranchStore] Migrating old format to new format")
            let migrated = oldBranches.map { old in
                Branch(
                    name: old.name,
                    bundleIDs: old.bundleIDs,
                    style: .custom,
                    customPrompt: old.prompt
                )
            }
            saveBranches(migrated)
            return migrated
        }

        vpLog("[AppBranchStore] JSON parse error")
        return []
    }

    /// Save branches to app-branches.json.
    func saveBranches(_ branches: [Branch]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(branches) else { return }
        ConfigDirectory.ensureExists()
        FileManager.default.createFile(atPath: filePath, contents: data)
        vpLog("[AppBranchStore] Saved \(branches.count) branches")
    }

    /// Resolve which branch matches a given bundle identifier.
    func resolve(bundleID: String?) -> Branch? {
        guard let bundleID else { return nil }
        return loadBranches().first { $0.bundleIDs.contains(bundleID) }
    }

    /// The name of the resolved branch, or "Default" if no match.
    func resolvedName(for bundleID: String?) -> String {
        resolve(bundleID: bundleID)?.name ?? "Default"
    }

    /// Whether the app-branches.json file exists.
    var fileExists: Bool {
        FileManager.default.fileExists(atPath: filePath)
    }

    // MARK: - Old format for migration

    private struct OldBranch: Codable {
        let name: String
        let bundleIDs: [String]
        let prompt: String
    }
}
