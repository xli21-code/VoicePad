import Foundation
import Testing

@testable import VoicePad

@Suite("Dictation context")
struct ContextTests {
    @Test("Slices keep text around the caret and clip to the limits")
    func slicesAroundCursor() {
        let value = String(repeating: "a", count: 500) + "CURSOR" + String(repeating: "b", count: 500)
        let caret = NSRange(location: 500, length: 0)
        let (before, after) = ContextReader.slices(from: value, selectedRange: caret,
                                                   maxBefore: 10, maxAfter: 5)
        #expect(before == String(repeating: "a", count: 10))
        #expect(after == "CURSO")
    }

    @Test("Selection expands the gap between before and after")
    func selectionSkipped() {
        let value = "前面的文字【选中】后面的文字"
        let ns = value as NSString
        let range = ns.range(of: "【选中】")
        let (before, after) = ContextReader.slices(from: value, selectedRange: range,
                                                   maxBefore: 10, maxAfter: 10)
        #expect(before == "前面的文字")
        #expect(after == "后面的文字")
    }

    @Test("Caret at the start or end yields one side only")
    func edges() {
        let start = ContextReader.slices(from: "abc", selectedRange: NSRange(location: 0, length: 0),
                                         maxBefore: 10, maxAfter: 10)
        #expect(start.0 == nil)
        #expect(start.1 == "abc")

        let end = ContextReader.slices(from: "abc", selectedRange: NSRange(location: 3, length: 0),
                                       maxBefore: 10, maxAfter: 10)
        #expect(end.0 == "abc")
        #expect(end.1 == nil)
    }

    @Test("Out-of-range caret is ignored instead of crashing")
    func outOfRange() {
        let result = ContextReader.slices(from: "abc", selectedRange: NSRange(location: 99, length: 0),
                                          maxBefore: 10, maxAfter: 10)
        #expect(result.0 == nil && result.1 == nil)
        let notFound = ContextReader.slices(from: "abc", selectedRange: NSRange(location: NSNotFound, length: 0),
                                            maxBefore: 10, maxAfter: 10)
        #expect(notFound.0 == nil && notFound.1 == nil)
    }

    @Test("Context block treats a selection as an edit instruction")
    func selectionMeansEdit() {
        let context = DictationContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                       role: "AXTextArea", selectedText: "这个方案不行",
                                       textBeforeCursor: nil, textAfterCursor: nil)
        let block = LLMPolisher.contextBlock(context)
        #expect(block.contains("Slack"))
        #expect(block.contains("AXTextArea"))
        #expect(block.contains("要修改的原文"))
        #expect(block.contains("这个方案不行"))
        #expect(!block.contains("光标前文"))
    }

    @Test("Context block passes surrounding text without asking for a continuation")
    func beforeCursorOnly() {
        let context = DictationContext(appName: "Notes", bundleID: "com.apple.Notes",
                                       role: "AXTextArea", selectedText: nil,
                                       textBeforeCursor: "上周的复盘是这样的：", textAfterCursor: nil)
        let block = LLMPolisher.contextBlock(context)
        #expect(block.contains("光标前文"))
        #expect(block.contains("上周的复盘是这样的："))
        #expect(block.contains("不要重复"))
        #expect(!block.contains("要修改的原文"))
    }

    @Test("An answer-shaped output is rejected as a polish result")
    func rejectsAssistantReplies() {
        let input = "把这个表第二列复制到新的工作表"
        #expect(!LLMPolisher.isUsableOutput("好的，我帮你把这个表的第二列复制过去。", for: input))
        #expect(!LLMPolisher.isUsableOutput("Here is the cleaned text.", for: input))
        // The same words are fine when the speaker actually said them.
        #expect(LLMPolisher.isUsableOutput("好的，我下午三点过去", for: "好的我下午三点过去"))
    }
}
