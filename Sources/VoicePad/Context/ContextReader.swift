import AppKit
import ApplicationServices

/// What the user was looking at when they started dictating.
///
/// Typeless's biggest quality lever is not the model — it is that the rewriter knows the
/// focused field, the text around the cursor and what is selected. This is the read side
/// of that, taken with the Accessibility API.
struct DictationContext {
    let appName: String?
    let bundleID: String?
    let role: String?
    /// Selected text. A non-empty selection means the user is speaking an *edit* instruction
    /// ("把上面这句改成……") rather than dictating fresh text.
    let selectedText: String?
    let textBeforeCursor: String?
    let textAfterCursor: String?

    var hasSelection: Bool { !(selectedText?.isEmpty ?? true) }

    static let empty = DictationContext(appName: nil, bundleID: nil, role: nil,
                                        selectedText: nil, textBeforeCursor: nil,
                                        textAfterCursor: nil)
}

/// Holds the context captured at key-down until the transcript is ready.
/// Reads happen on a background task because AX can block; the pipeline only needs the
/// value a few seconds later, so it must not wait.
final class ContextHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DictationContext?

    func set(_ context: DictationContext?) {
        lock.lock(); value = context; lock.unlock()
    }

    func take() -> DictationContext? {
        lock.lock()
        defer { value = nil; lock.unlock() }
        return value
    }
}

enum ContextReader {
    /// AX calls can block for seconds when the target app is busy, so every read is
    /// bounded by a short messaging timeout and the caller never waits on the main thread.
    private static let messagingTimeout: Float = 0.35
    private static let maxBefore = 800
    private static let maxAfter = 200
    private static let maxSelected = 2000

    static func read() -> DictationContext {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .empty }
        // Reading our own UI tells the model nothing and can re-enter our own window.
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return .empty }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRaw = focusedRef,
              CFGetTypeID(focusedRaw) == AXUIElementGetTypeID() else {
            return DictationContext(appName: app.localizedName, bundleID: app.bundleIdentifier,
                                    role: nil, selectedText: nil, textBeforeCursor: nil, textAfterCursor: nil)
        }
        let element = focusedRaw as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)

        let role = string(element, kAXRoleAttribute)
        let selected = string(element, kAXSelectedTextAttribute).map { clip($0, maxSelected) }
        let (before, after) = surroundingText(of: element)

        return DictationContext(
            appName: app.localizedName,
            bundleID: app.bundleIdentifier,
            role: role,
            selectedText: selected?.isEmpty == true ? nil : selected,
            textBeforeCursor: before,
            textAfterCursor: after
        )
    }

    /// Text around the caret, derived from the field value plus the selected range.
    /// Returns nil for both when the field exposes no value or no range.
    static func surroundingText(of element: AXUIElement) -> (String?, String?) {
        guard let value = string(element, kAXValueAttribute), !value.isEmpty,
              let range = selectedRange(of: element) else { return (nil, nil) }
        return slices(from: value, selectedRange: range, maxBefore: maxBefore, maxAfter: maxAfter)
    }

    /// Pure slicing helper, kept separate so it can be tested without a real UI.
    static func slices(from value: String, selectedRange: NSRange,
                       maxBefore: Int, maxAfter: Int) -> (String?, String?) {
        let ns = value as NSString
        let length = ns.length
        guard selectedRange.location != NSNotFound, selectedRange.location <= length else { return (nil, nil) }

        let beforeEnd = min(selectedRange.location, length)
        let beforeStart = max(0, beforeEnd - maxBefore)
        let afterStart = min(beforeEnd + selectedRange.length, length)
        let afterEnd = min(afterStart + maxAfter, length)

        let before = beforeStart < beforeEnd ? ns.substring(with: NSRange(location: beforeStart, length: beforeEnd - beforeStart)) : ""
        let after = afterStart < afterEnd ? ns.substring(with: NSRange(location: afterStart, length: afterEnd - afterStart)) : ""
        return (before.isEmpty ? nil : before, after.isEmpty ? nil : after)
    }

    // MARK: - AX helpers

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let raw = ref, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        return NSRange(location: range.location, length: max(0, range.length))
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit))
    }
}
