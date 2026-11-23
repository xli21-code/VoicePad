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
    /// NSEvent global monitors are passive: they observe, they cannot swallow. The remote
    /// key has to be eaten before the focused app sees it (otherwise it leaks as an F18
    /// keystroke, which the target app answers with a beep on every repeat), so it runs
    /// through a tap of its own.
    private var remoteKeyTap: CFMachPort?
    private var remoteKeyRunLoopSource: CFRunLoopSource?
    private var remoteKeyHeld = false
    private var remoteKeyLastSeen: Date?
    /// F20: not the push-to-talk key, but the remote's companion autorepeat.
    private static let remoteNoiseKeyCode: Int64 = 96
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

        installRemoteKeyTap()
    }

    /// Swallows the remote push-to-talk key (F18) so it never reaches the focused app.
    /// Without Accessibility trust the tap cannot be created; the passive monitors above
    /// still drive recording, the key just leaks.
    private func installRemoteKeyTap() {
        guard remoteKeyTap == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

                // macOS disables a tap that runs long; re-arm it instead of going silent.
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    monitor.reenableRemoteKeyTap()
                    return Unmanaged.passUnretained(event)
                }

                if monitor.handleRemoteKey(cgEvent: event) {
                    return nil
                }
                monitor.logStrayKey(cgEvent: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap else {
            vpLog("[HotkeyMonitor] F18 tap not created (no Accessibility trust) — remote key will leak to the focused app")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        remoteKeyTap = tap
        remoteKeyRunLoopSource = source
        vpLog("[HotkeyMonitor] F18 tap installed — remote key swallowed")
    }

    private func reenableRemoteKeyTap() {
        guard let remoteKeyTap else { return }
        CGEvent.tapEnable(tap: remoteKeyTap, enable: true)
        vpLog("[HotkeyMonitor] F18 tap was disabled by the system — re-enabled")
    }

    private func removeRemoteKeyTap() {
        if let source = remoteKeyRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            remoteKeyRunLoopSource = nil
        }
        if let tap = remoteKeyTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            remoteKeyTap = nil
        }
    }

    private func removeMonitors() {
        removeRemoteKeyTap()
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
        return applyRemoteKey(
            isDown: event.type == .keyDown,
            isRepeat: event.isARepeat,
            hasModifiers: !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        )
    }

    /// Same state machine, fed by the event tap (which sees F18 before any NSEvent monitor).
    @discardableResult
    func handleRemoteKey(cgEvent event: CGEvent) -> Bool {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        // The remote autorepeats F20 for as long as the voice key is held. F18 brackets the
        // press, F20 is what leaks to the focused app and beeps on every repeat — the
        // "哒哒哒" the user hears. Only swallowed inside a press, so a real F20 still works.
        if code == Self.remoteNoiseKeyCode {
            let insidePress = remoteKeyHeld
                || (remoteKeyLastSeen.map { Date().timeIntervalSince($0) < 2 } ?? false)
            return insidePress
        }
        guard code == 79 else { return false }
        let chordFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let hasModifiers = !event.flags.intersection(chordFlags).isEmpty
        // Every path that reaches the tap is logged: when the remote key leaks (or when the
        // tap stops receiving it), this is the only place that can tell the two apart.
        // The remote sends more than one report per press (a second keycode is one of the
        // two ways a key can still beep after we swallow F18), and "it jumps to another
        // window" needs a name attached, so both are logged here.
        remoteKeyLastSeen = Date()
        vpLog("[HotkeyMonitor] F18 via tap: \(event.type == .keyDown ? "down" : "up")"
              + " repeat=\(isRepeat) mods=\(hasModifiers) held=\(remoteKeyHeld)"
              + " active=\(isRecordingActive) front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")")
        return applyRemoteKey(isDown: event.type == .keyDown,
                              isRepeat: isRepeat,
                              hasModifiers: hasModifiers)
    }

    /// Diagnostic only: a second keycode arriving in the same press would leak past the tap
    /// and beep, and this is the only way to see it without a HID-level sniffer.
    func logStrayKey(cgEvent event: CGEvent) {
        guard let seen = remoteKeyLastSeen,
              Date().timeIntervalSince(seen) < 3 else { return }
        vpLog("[HotkeyMonitor] stray key near F18: code=\(event.getIntegerValueField(.keyboardEventKeycode))"
              + " type=\(event.type.rawValue) repeat=\(event.getIntegerValueField(.keyboardEventAutorepeat))"
              + " flags=\(event.flags.rawValue)")
    }

    @discardableResult
    private func applyRemoteKey(isDown: Bool, isRepeat: Bool, hasModifiers: Bool) -> Bool {
        if isDown {
            guard !isRepeat, !remoteKeyHeld, !isRecordingActive, !hasModifiers else { return true }
            remoteKeyHeld = true
            lastTapTime = nil
            longPressTimer?.invalidate()
            isRecordingActive = true
            onKeyDown?()
        } else if remoteKeyHeld {
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
