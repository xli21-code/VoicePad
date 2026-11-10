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
    /// How the element was found (focused / window / tree / systemwide), for debugging.
    let source: String?
    /// Selected text. A non-empty selection means the user is speaking an *edit* instruction
    /// ("把上面这句改成……") rather than dictating fresh text.
    let selectedText: String?
    let textBeforeCursor: String?
    let textAfterCursor: String?

    var hasSelection: Bool { !(selectedText?.isEmpty ?? true) }

    static let empty = DictationContext(appName: nil, bundleID: nil, role: nil, source: nil,
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
    /// Tree walking is best-effort; cap it so a huge UI can never stall the read.
    private static let maxNodes = 120
    /// Wall-clock budget for the whole read: AX timeouts are per-call, so a pathological
    /// tree could otherwise add up to minutes.
    private static let budget: TimeInterval = 0.5

    static func read() -> DictationContext {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .empty }
        // Reading our own UI tells the model nothing and can re-enter our own window.
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return .empty }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, messagingTimeout)

        // Chromium / Electron only expose their real accessibility tree once this is set.
        // Without it a Chrome text field reports an empty value.
        setBool(appElement, "AXEnhancedUserInterface", true)

        var (element, source) = resolveElement(appElement)

        // A window or a container often has no text of its own: look for a descendant that
        // does before giving up on the context entirely.
        if textInfo(of: element).value == nil, let found = findTextElement(from: element) {
            element = found
            source += "+tree"
        }

        let info = textInfo(of: element)
        let role = string(element, kAXRoleAttribute)

        return DictationContext(
            appName: app.localizedName,
            bundleID: app.bundleIdentifier,
            role: role,
            source: source,
            selectedText: info.selected.map { clip($0, maxSelected) },
            textBeforeCursor: info.before,
            textAfterCursor: info.after
        )
    }

    // MARK: - Element resolution

    private static func resolveElement(_ appElement: AXUIElement) -> (AXUIElement, String) {
        if let focused = element(appElement, kAXFocusedUIElementAttribute) {
            return (focused, "focused")
        }
        if let window = element(appElement, kAXFocusedWindowAttribute) {
            if let inner = element(window, kAXFocusedUIElementAttribute) {
                return (inner, "window")
            }
            return (window, "window")
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        if let focused = element(system, kAXFocusedUIElementAttribute) {
            return (focused, "systemwide")
        }
        return (appElement, "app")
    }

    /// Breadth-first search for the first descendant that actually carries text.
    private static func findTextElement(from root: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var visited = 0
        var index = 0
        let deadline = Date().addingTimeInterval(budget)

        while index < queue.count && visited < maxNodes && Date() < deadline {
            let (node, depth) = queue[index]
            index += 1
            visited += 1

            if textInfo(of: node).value != nil { return node }
            guard depth < 10 else { continue }

            var childrenRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                  let children = childrenRef as? [AXUIElement] else { continue }
            for child in children { queue.append((child, depth + 1)) }
        }
        return nil
    }

    // MARK: - Text extraction

    private struct TextInfo {
        let value: String?
        let selected: String?
        let before: String?
        let after: String?
    }

    private static func textInfo(of element: AXUIElement) -> TextInfo {
        guard let value = string(element, kAXValueAttribute), !value.isEmpty else {
            return TextInfo(value: nil, selected: nil, before: nil, after: nil)
        }
        guard let range = selectedRange(of: element) else {
            return TextInfo(value: value, selected: nil, before: nil, after: nil)
        }
        let (before, after) = slices(from: value, selectedRange: range,
                                     maxBefore: maxBefore, maxAfter: maxAfter)
        return TextInfo(value: value, selected: selectedSlice(from: value, range: range), before: before, after: after)
    }

    /// The selected substring, taken from the field value + range. More reliable than
    /// `AXSelectedText`, which many apps do not implement.
    static func selectedSlice(from value: String, range: NSRange) -> String? {
        let ns = value as NSString
        guard range.length > 0, range.location != NSNotFound,
              range.location + range.length <= ns.length else { return nil }
        let text = ns.substring(with: range)
        return text.isEmpty ? nil : text
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

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &ref) == .success,
              let raw = ref, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let child = raw as! AXUIElement
        AXUIElementSetMessagingTimeout(child, messagingTimeout)
        return child
    }

    private static func selectedRange(of element: AXUIElement) -> NSRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &ref) == .success,
              let raw = ref, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(raw as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        return NSRange(location: range.location, length: max(0, range.length))
    }

    private static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) {
        AXUIElementSetAttributeValue(element, attribute as CFString, (value ? kCFBooleanTrue : kCFBooleanFalse))
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit))
    }
}
