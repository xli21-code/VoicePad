import AppKit

/// Monitors global keyboard events for double-tap-to-record hotkey.
/// Double-tap the configured modifier key to start recording.
/// Single tap while recording to stop.
/// Chord rejection prevents Ctrl+C etc. from triggering.
///
/// Hotkey options:
///   Left Control (59), Right Control (62),
///   Left Option (58), Right Option (61),
///   Left Command (55), Right Command (54),
///   Left Shift (56), Right Shift (60)
final class HotkeyMonitor {
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    var onLongPress: (() -> Void)?

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    // Double-tap detection state
    private var isKeyDown = false
    private var otherKeyPressed = false          // chord rejection
    private var currentKeyDownTime: Date?        // when current press started
    private var lastTapTime: Date?               // time of last completed tap (quick press-release)

    /// Whether recording is currently active (managed by this monitor, reset by AppState if needed).
    var isRecordingActive = false

    private let doubleTapInterval: TimeInterval = 0.4   // max gap between two taps
    private let maxTapDuration: TimeInterval = 0.35      // max hold duration to count as a "tap"
    private let longPressDuration: TimeInterval = 0.6    // min hold for long-press correction
    private var longPressTimer: Timer?

    /// The keyCode of the configured hotkey modifier.
    var hotkeyKeyCode: Int {
        didSet {
            UserDefaults.standard.set(hotkeyKeyCode, forKey: "hotkeyKeyCode")
            vpLog("[HotkeyMonitor] Hotkey changed to keyCode \(hotkeyKeyCode) (\(Self.nameForKeyCode(hotkeyKeyCode)))")
        }
    }

    /// All available hotkey options: (keyCode, displayName)
    static let hotkeyOptions: [(keyCode: Int, name: String)] = [
        (62, "Right Control"),
        (59, "Left Control"),
        (61, "Right Option"),
        (58, "Left Option"),
        (54, "Right Command"),
        (55, "Left Command"),
        (60, "Right Shift"),
        (56, "Left Shift"),
    ]

    static func nameForKeyCode(_ keyCode: Int) -> String {
        hotkeyOptions.first(where: { $0.keyCode == keyCode })?.name ?? "Key \(keyCode)"
    }

    init() {
        let saved = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        // Default to Right Control (62) if no saved value
        hotkeyKeyCode = saved != 0 ? saved : 62
    }

    func start() {
        // Monitor modifier key changes globally
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
        }

        // Also monitor in our own app's windows
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlags(event)
            return event
        }

        // Monitor non-modifier key presses for chord rejection
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            guard let self, self.isKeyDown else { return }
            self.otherKeyPressed = true
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, self.isKeyDown {
                self.otherKeyPressed = true
            }
            return event
        }
    }

    func stop() {
        longPressTimer?.invalidate()
        longPressTimer = nil
        if let monitor = globalFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            globalFlagsMonitor = nil
        }
        if let monitor = localFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            localFlagsMonitor = nil
        }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
    }

    private func handleFlags(_ event: NSEvent) {
        let eventKeyCode = Int(event.keyCode)

        // Check if this event is for our configured hotkey
        guard eventKeyCode == hotkeyKeyCode else { return }

        let modifierDown = isModifierDown(event: event, keyCode: hotkeyKeyCode)

        if modifierDown && !isKeyDown {
            // Key pressed down
            isKeyDown = true
            otherKeyPressed = false
            currentKeyDownTime = Date()
            longPressTimer?.invalidate()

            // Start long-press timer (only when not recording)
            if !isRecordingActive {
                longPressTimer = Timer.scheduledTimer(withTimeInterval: longPressDuration, repeats: false) { [weak self] _ in
                    guard let self, self.isKeyDown, !self.otherKeyPressed else { return }
                    vpLog("[HotkeyMonitor] Long press detected → CORRECTION")
                    self.longPressTimer = nil
                    // Mark as consumed so key-up won't trigger a tap
                    self.currentKeyDownTime = nil
                    self.onLongPress?()
                }
            }
        } else if !modifierDown && isKeyDown {
            // Key released
            isKeyDown = false
            longPressTimer?.invalidate()
            longPressTimer = nil

            // If long press already consumed this press, skip
            guard let keyDownTime = currentKeyDownTime else { return }

            // Check if this was a quick tap (not a long hold)
            let holdDuration = Date().timeIntervalSince(keyDownTime)

            // If chord detected or held too long, not a tap — ignore
            if otherKeyPressed {
                vpLog("[HotkeyMonitor] Chord detected, ignoring tap")
                otherKeyPressed = false
                return
            }
            if holdDuration > maxTapDuration {
                vpLog("[HotkeyMonitor] Hold too long (\(String(format: "%.2f", holdDuration))s), ignoring")
                return
            }

            // It's a valid tap
            let now = Date()

            if isRecordingActive {
                // Single tap while recording → stop
                vpLog("[HotkeyMonitor] Tap while recording → STOP")
                isRecordingActive = false
                onKeyUp?()
            } else {
                // Check for double-tap
                if let lastTap = lastTapTime, now.timeIntervalSince(lastTap) < doubleTapInterval {
                    // Double-tap → start recording
                    vpLog("[HotkeyMonitor] Double-tap → START")
                    lastTapTime = nil
                    isRecordingActive = true
                    onKeyDown?()
                } else {
                    // First tap — wait for second
                    vpLog("[HotkeyMonitor] First tap, waiting for double-tap...")
                    lastTapTime = now
                }
            }
        }
    }

    /// Whether this was a chord (modifier + other key). Used by AppState to decide
    /// whether to discard the recording.
    var wasChord: Bool { false } // Chords are now handled internally — never passed to AppState

    /// Determine if the modifier key for the given keyCode is currently pressed.
    private func isModifierDown(event: NSEvent, keyCode: Int) -> Bool {
        let flags = event.modifierFlags
        switch keyCode {
        case 59, 62: // Left/Right Control
            return flags.contains(.control)
        case 58, 61: // Left/Right Option
            return flags.contains(.option)
        case 55, 54: // Left/Right Command
            return flags.contains(.command)
        case 56, 60: // Left/Right Shift
            return flags.contains(.shift)
        default:
            return false
        }
    }

    deinit {
        stop()
    }
}
