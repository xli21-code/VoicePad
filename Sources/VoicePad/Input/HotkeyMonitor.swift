import AppKit

/// Monitors global keyboard events for push-to-talk hotkey.
/// Default: Left Control key (hold to record, release to stop).
final class HotkeyMonitor {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?

    private var flagsMonitor: Any?
    private var isControlPressed = false
    private let modifierKey: NSEvent.ModifierFlags = .control

    func start() {
        // Monitor modifier key changes globally
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
        }

        // Also monitor in our own app's windows
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
            return event
        }
    }

    func stop() {
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let controlDown = event.modifierFlags.contains(modifierKey)

        if controlDown && !isControlPressed {
            // Control just pressed
            isControlPressed = true
            vpLog("[HotkeyMonitor] Control DOWN")
            onKeyDown?()
        } else if !controlDown && isControlPressed {
            // Control just released
            isControlPressed = false
            vpLog("[HotkeyMonitor] Control UP")
            onKeyUp?()
        }
    }

    deinit {
        stop()
    }
}
