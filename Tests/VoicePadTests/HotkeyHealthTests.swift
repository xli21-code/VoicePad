import AppKit
import Testing

@testable import VoicePad

/// The hotkey is not an event tap — it is NSEvent global monitors — and macOS never says
/// when those stop delivering. These tests pin the state machine that decides whether the
/// hotkey can work, and the two transitions that must recover on their own.
@Suite("Hotkey health")
struct HotkeyHealthTests {
    private func monitor() -> HotkeyMonitor {
        let monitor = HotkeyMonitor()
        monitor.isTrusted = { true }
        monitor.isSecureInput = { false }
        return monitor
    }

    @Test func healthyOnlyWhenInstalledTrustedAndUnobstructed() {
        #expect(HotkeyMonitor.health(monitorsInstalled: true, isTrusted: true, isSecureInput: false) == .ok)
        #expect(HotkeyMonitor.health(monitorsInstalled: false, isTrusted: true, isSecureInput: false) == .stopped)
        #expect(HotkeyMonitor.health(monitorsInstalled: true, isTrusted: false, isSecureInput: false) == .notTrusted)
        // A secured field beats a granted permission: the events go nowhere.
        #expect(HotkeyMonitor.health(monitorsInstalled: true, isTrusted: true, isSecureInput: true) == .secureInput)
    }

    @Test func startInstallsMonitorsAndStopRemovesThem() {
        let monitor = monitor()
        monitor.start()
        defer { monitor.stop() }
        #expect(monitor.health() == .ok)
        monitor.stop()
        #expect(monitor.health() == .stopped)
    }

    @Test func healthChangeIsReportedOncePerTransition() {
        let monitor = monitor()
        monitor.start()
        defer { monitor.stop() }

        var reported: [HotkeyMonitor.Health] = []
        monitor.onHealthChange = { reported.append($0) }

        // Same state twice: no callback, no log spam from a 20 s timer.
        monitor.checkHealth()
        monitor.checkHealth()
        #expect(reported.isEmpty)

        monitor.isTrusted = { false }
        monitor.checkHealth()
        monitor.checkHealth()
        #expect(reported == [.notTrusted])

        // Permission comes back: the monitor recovers without a relaunch.
        monitor.isTrusted = { true }
        monitor.checkHealth()
        #expect(reported == [.notTrusted, .ok])
        #expect(monitor.health() == .ok)
    }

    @Test func secureInputIsTransientAndSelfHeals() {
        let monitor = monitor()
        monitor.start()
        defer { monitor.stop() }

        monitor.isSecureInput = { true }
        monitor.checkHealth()
        #expect(monitor.health() == .secureInput)

        monitor.isSecureInput = { false }
        monitor.checkHealth()
        #expect(monitor.health() == .ok)
    }
}
