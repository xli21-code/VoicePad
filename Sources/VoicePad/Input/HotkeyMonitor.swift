import AppKit
import Carbon

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
    /// Fires when the monitor's health changes, so the menu bar can say why the hotkey
    /// is dead instead of leaving the user with "it stopped working".
    var onHealthChange: ((Health) -> Void)?

    /// Why the hotkey may not be working. There is no event tap in this app — the hotkey
    /// is NSEvent global monitors — and macOS gives no callback when those stop
    /// delivering, so the state has to be probed.
    enum Health: Equatable {
        /// Monitors installed and events can arrive.
        case ok
        /// Accessibility trust is gone: global monitors go silent with no error at all.
        case notTrusted
        /// A secure input field (password prompt, secure terminal) is swallowing key
        /// events. Transient and self-healing, but it explains a recording that never
        /// started, so it is logged rather than hidden.
        case secureInput
        /// No monitors installed — should not happen, heals by itself.
        case stopped
    }

    /// Injected so the state machine can be tested without the real TCC database.
    var isTrusted: () -> Bool = { AXIsProcessTrusted() }
    var isSecureInput: () -> Bool = { IsSecureEventInputEnabled() }

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?
    private var remoteKeyHeld = false
    private var healthTimer: Timer?
    private(set) var lastHealth: Health = .stopped

    /// 20 s is cheap (two syscalls) and short enough that a permission revoked mid-session
    /// is noticed before the user files it as "the app broke".
    private let healthInterval: TimeInterval = 20

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
        installMonitors()
        lastHealth = health()
        startWatchdog()
        // The line to look for when someone reports "the hotkey stopped working".
        vpLog("[HotkeyMonitor] started, health=\(lastHealth)")
    }

    /// Re-installs the monitors without touching the watchdog. Global monitors registered
    /// under a TCC state that has since changed do not necessarily start delivering again;
    /// re-registering is the only way to be sure.
    func restart() {
        removeMonitors()
        installMonitors()
    }

    private func installMonitors() {
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
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            if self?.handleRemoteKey(event) == true { return }
            guard event.type == .keyDown else { return }
            guard let self, self.isKeyDown else { return }
            self.otherKeyPressed = true
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            if self?.handleRemoteKey(event) == true { return nil }
            guard event.type == .keyDown else { return event }
            if let self, self.isKeyDown {
                self.otherKeyPressed = true
            }
            return event
        }
    }

    private func removeMonitors() {
        for monitor in [globalFlagsMonitor, localFlagsMonitor, globalKeyMonitor, localKeyMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyMonitor = nil
        localKeyMonitor = nil
    }

    func stop() {
        healthTimer?.invalidate()
        healthTimer = nil
        if remoteKeyHeld {
            remoteKeyHeld = false
            isRecordingActive = false
            onKeyUp?()
        }
        longPressTimer?.invalidate()
        longPressTimer = nil
        removeMonitors()
        lastHealth = .stopped
    }

    // MARK: - Health watchdog

    /// The hotkey fails silently: with trust revoked the monitors simply stop firing, and
    /// there is nothing in the log to say so. Probe the state, and tell the menu bar.
    func checkHealth() {
        let current = health()
        let previous = lastHealth
        guard current != previous else { return }
        lastHealth = current
        vpLog("[HotkeyMonitor] health \(previous) → \(current)")
        onHealthChange?(current)

        // Trust granted while the app was running, or monitors missing for any reason:
        // re-registration is free and is the only state change that can actually recover.
        if current == .ok || current == .stopped {
            restart()
        }
    }

    private func startWatchdog() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: healthInterval, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
    }

    func health() -> Health {
        Self.health(monitorsInstalled: globalFlagsMonitor != nil,
                    isTrusted: isTrusted(),
                    isSecureInput: isSecureInput())
    }

    static func health(monitorsInstalled: Bool, isTrusted: Bool, isSecureInput: Bool) -> Health {
        guard monitorsInstalled else { return .stopped }
        guard isTrusted else { return .notTrusted }
        // Secure input wins over ok: events are delivered to nobody while it is on.
        if isSecureInput { return .secureInput }
        return .ok
    }

    /// F18 is a separate push-to-talk input for the remote; modifier gestures stay unchanged.
    @discardableResult
    func handleRemoteKey(_ event: NSEvent) -> Bool {
        guard event.keyCode == 79 else { return false }
        if event.type == .keyDown {
            guard !event.isARepeat, !remoteKeyHeld, !isRecordingActive,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            else { return true }
            remoteKeyHeld = true
            lastTapTime = nil
            longPressTimer?.invalidate()
            isRecordingActive = true
            onKeyDown?()
        } else if event.type == .keyUp, remoteKeyHeld {
            remoteKeyHeld = false
            isRecordingActive = false
            onKeyUp?()
        }
        return true
    }

    private func handleFlags(_ event: NSEvent) {
        guard !remoteKeyHeld else { return }
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

            // Long-press correction is opt-in: it fires after 0.6 s of holding the hotkey,
            // which is exactly what a push-to-talk user does while thinking. It then steals
            // focus with a panel, which looks like "something popped up" mid-sentence.
            let longPressEnabled = UserDefaults.standard.bool(forKey: "longPressCorrection")
            if longPressEnabled, !isRecordingActive {
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
