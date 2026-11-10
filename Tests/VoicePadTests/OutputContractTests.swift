import Foundation
import Testing

@testable import VoicePad

@Suite("Output contract")
struct OutputContractTests {

    @Test("Terminals and editors ask for identifiers to be left alone")
    func codeApps() {
        #expect(OutputContract.forApp(bundleID: "com.apple.Terminal") == .code)
        #expect(OutputContract.forApp(bundleID: "com.microsoft.VSCode") == .code)
        #expect(OutputContract.forApp(bundleID: "com.apple.dt.Xcode") == .code)
        #expect(OutputContract.forApp(bundleID: "com.jetbrains.intellij") == .code)
    }

    @Test("Chat apps get the strictest shape")
    func chatApps() {
        #expect(OutputContract.forApp(bundleID: "com.tencent.xinWeChat") == .chat)
        #expect(OutputContract.forApp(bundleID: "com.tinyspeck.slackmacgap") == .chat)
    }

    @Test("Mail and note apps are told apart")
    func mailAndDocuments() {
        #expect(OutputContract.forApp(bundleID: "com.apple.mail") == .email)
        #expect(OutputContract.forApp(bundleID: "com.apple.Notes") == .document)
    }

    @Test("Bundle id matching ignores case")
    func caseInsensitive() {
        #expect(OutputContract.forApp(bundleID: "COM.APPLE.TERMINAL") == .code)
    }

    @Test("An unknown app or no app at all falls back to the conservative contract")
    func unknownFallsBack() {
        #expect(OutputContract.forApp(bundleID: "com.example.unknown") == .neutral)
        #expect(OutputContract.forApp(bundleID: nil) == .neutral)
    }

    @Test("Only the document contract allows paragraphs")
    func paragraphOnlyForDocuments() {
        #expect(OutputContract.document.promptSection.contains("可以分段"))
        #expect(!OutputContract.chat.promptSection.contains("可以分段"))
        #expect(!OutputContract.code.promptSection.contains("可以分段"))
        #expect(!OutputContract.email.promptSection.contains("可以分段"))
    }

    @Test("The code contract protects identifiers and forbids markdown")
    func codeContractRules() {
        let section = OutputContract.code.promptSection
        #expect(section.contains("原样保留"))
        #expect(section.contains("Markdown"))
        #expect(section.contains("不要补句号"))
    }

    @Test("Neutral matches the chat contract, so unknown apps behave as before")
    func neutralIsUnchanged() {
        #expect(OutputContract.neutral.promptSection == OutputContract.chat.promptSection)
        #expect(OutputContract.neutral.promptSection.contains("不加标题、列表符号"))
    }
}
