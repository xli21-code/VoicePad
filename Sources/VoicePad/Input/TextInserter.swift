import AppKit
import Carbon.HIToolbox

/// Pastes text into the previously active app via Cmd+V.
/// Saves and restores the clipboard so the user's existing content isn't lost.
final class TextInserter {
    /// Paste text by writing to clipboard and simulating Cmd+V, then restore clipboard.
    func paste(_ text: String, to app: NSRunningApplication?) {
        vpLog("[TextInserter] paste called, text='\(text.prefix(50))', app=\(app?.localizedName ?? "nil")")
        let pasteboard = NSPasteboard.general

        // 1. Save existing clipboard contents
        let savedItems = savePasteboard(pasteboard)

        // 2. Write transcribed text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let changeCountAfterSet = pasteboard.changeCount
        vpLog("[TextInserter] clipboard set (changeCount=\(changeCountAfterSet)), activating app...")

        // 3. Activate the target app and paste
        if let app, app.isTerminated == false {
            app.activate()

            // Wait for activation, then simulate Cmd+V
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                vpLog("[TextInserter] simulating Cmd+V")
                self.simulatePaste()

                // 4. Restore clipboard after paste completes
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if pasteboard.changeCount == changeCountAfterSet {
                        self.restorePasteboard(pasteboard, items: savedItems)
                        vpLog("[TextInserter] clipboard restored")
                    } else {
                        vpLog("[TextInserter] clipboard was modified externally, skipping restore")
                    }
                }
            }
        } else {
            vpLog("[TextInserter] Target app unavailable — text in clipboard")
        }
    }

    /// Try to replace the original text in the target app via Accessibility API.
    /// Does NOT touch the clipboard — caller is responsible for clipboard state.
    /// Calls `completion` on main thread when done.
    func replaceOriginal(_ original: String, with replacement: String, in app: NSRunningApplication?, completion: (() -> Void)? = nil) {
        vpLog("[TextInserter] replaceOriginal: '\(original.prefix(30))' → '\(replacement.prefix(30))'")

        guard let app, !app.isTerminated else {
            vpLog("[TextInserter] replaceOriginal: target app unavailable")
            completion?()
            return
        }

        guard AXIsProcessTrusted() else {
            vpLog("[TextInserter] replaceOriginal: Accessibility not trusted")
            completion?()
            return
        }

        app.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let appRef = AXUIElementCreateApplication(app.processIdentifier)

            // Get focused element
            var focusedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appRef, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
                  let focused = focusedRef else {
                vpLog("[TextInserter] replaceOriginal: can't get focused element")
                completion?()
                return
            }

            let element = focused as! AXUIElement

            // Read current text
            var valueRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
                  let currentText = valueRef as? String else {
                vpLog("[TextInserter] replaceOriginal: can't read text value")
                completion?()
                return
            }

            vpLog("[TextInserter] replaceOriginal: field has \(currentText.count) chars")

            // Find original text (search backwards)
            let nsString = currentText as NSString
            let nsRange = nsString.range(of: original, options: .backwards)

            guard nsRange.location != NSNotFound else {
                vpLog("[TextInserter] replaceOriginal: original not found in field")
                completion?()
                return
            }

            vpLog("[TextInserter] replaceOriginal: found at NSRange \(nsRange)")

            // Strategy 1: Direct AXValue replacement (most reliable when supported)
            let newText = nsString.replacingCharacters(in: nsRange, with: replacement)
            let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, newText as CFTypeRef)
            if setResult == .success {
                vpLog("[TextInserter] replaceOriginal: replaced via AXValue")
                completion?()
                return
            }

            // Strategy 2: AXSelectedTextRange + Cmd+V (clipboard already has replacement)
            var cfRange = CFRange(location: nsRange.location, length: nsRange.length)
            if let axRange = AXValueCreate(.cfRange, &cfRange) {
                let selectResult = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
                if selectResult == .success {
                    vpLog("[TextInserter] replaceOriginal: selection set, pasting")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        self.simulatePaste()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { completion?() }
                    }
                    return
                }
            }

            vpLog("[TextInserter] replaceOriginal: all AX methods failed, text is in clipboard")
            completion?()
        }
    }

    // MARK: - Clipboard Save/Restore

    private func savePasteboard(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            if !dict.isEmpty {
                items.append(dict)
            }
        }
        return items
    }

    private func restorePasteboard(_ pasteboard: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        for dict in items {
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
    }

    // MARK: - Key Simulation

    private func simulatePaste() {
        // Try CGEvent first (requires Accessibility permission)
        let source = CGEventSource(stateID: .hidSystemState)

        if AXIsProcessTrusted(),
           let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) {
            keyDown.flags = .maskCommand
            keyUp.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
            vpLog("[TextInserter] pasted via CGEvent")
        } else {
            // Fallback: AppleScript
            vpLog("[TextInserter] CGEvent unavailable, trying AppleScript")
            let script = NSAppleScript(source: """
                tell application "System Events" to keystroke "v" using command down
            """)
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            if let error {
                vpLog("[TextInserter] AppleScript failed: \(error)")
                // Last resort: tell user text is in clipboard
                vpLog("[TextInserter] text remains in clipboard, user can Cmd+V manually")
            } else {
                vpLog("[TextInserter] pasted via AppleScript")
            }
        }
    }
}
