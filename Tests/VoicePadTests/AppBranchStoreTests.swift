import Foundation
import Testing

@testable import VoicePad

@Suite("AppBranchStore")
struct AppBranchStoreTests {

    // MARK: - BranchStyle

    @Test("Preset styles return non-empty built-in prompts")
    func presetPrompts() {
        for style in BranchStyle.allCases where style != .custom {
            #expect(!style.builtInPrompt.isEmpty, "Style \(style.rawValue) has empty prompt")
        }
    }

    @Test("Custom style has empty built-in prompt")
    func customPromptEmpty() {
        #expect(BranchStyle.custom.builtInPrompt.isEmpty)
    }

    @Test("All styles have display names")
    func displayNames() {
        for style in BranchStyle.allCases {
            #expect(!style.displayName.isEmpty)
        }
    }

    // MARK: - Branch stylePrompt

    @Test("Preset branch returns built-in prompt")
    func branchPresetPrompt() {
        let branch = Branch(name: "Code", bundleIDs: [], style: .coding)
        #expect(branch.stylePrompt == BranchStyle.coding.builtInPrompt)
    }

    @Test("Custom branch returns customPrompt")
    func branchCustomPrompt() {
        let branch = Branch(name: "My Style", bundleIDs: [], style: .custom, customPrompt: "Be concise")
        #expect(branch.stylePrompt == "Be concise")
    }

    @Test("Custom branch with nil customPrompt returns empty string")
    func branchCustomNilPrompt() {
        let branch = Branch(name: "Empty", bundleIDs: [], style: .custom, customPrompt: nil)
        #expect(branch.stylePrompt == "")
    }

    // MARK: - Branch Codable

    @Test("Branch round-trips through JSON")
    func branchRoundtrip() throws {
        let branch = Branch(
            name: "Coding",
            bundleIDs: ["com.apple.dt.Xcode"],
            style: .coding,
            customPrompt: nil
        )
        let data = try JSONEncoder().encode(branch)
        let decoded = try JSONDecoder().decode(Branch.self, from: data)
        #expect(decoded.name == "Coding")
        #expect(decoded.bundleIDs == ["com.apple.dt.Xcode"])
        #expect(decoded.style == .coding)
        #expect(decoded.customPrompt == nil)
    }

    @Test("BranchStyle round-trips through JSON")
    func styleRoundtrip() throws {
        for style in BranchStyle.allCases {
            let data = try JSONEncoder().encode(style)
            let decoded = try JSONDecoder().decode(BranchStyle.self, from: data)
            #expect(decoded == style)
        }
    }
}
