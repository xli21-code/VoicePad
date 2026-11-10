import AppKit
import Testing

@testable import VoicePad

@Suite("Remote push-to-talk")
struct RemoteHotkeyTests {
    private func key(_ type: NSEvent.EventType, code: UInt16 = 79,
                     repeatKey: Bool = false, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                        timestamp: 0, windowNumber: 0, context: nil,
                        characters: "", charactersIgnoringModifiers: "",
                        isARepeat: repeatKey, keyCode: code)!
    }

    @Test func holdStartsOnceAndReleaseStopsOnce() {
        let monitor = HotkeyMonitor()
        var starts = 0
        var stops = 0
        monitor.onKeyDown = { starts += 1 }
        monitor.onKeyUp = { stops += 1 }
        monitor.handleRemoteKey(key(.keyDown))
        monitor.handleRemoteKey(key(.keyDown, repeatKey: true))
        monitor.handleRemoteKey(key(.keyDown))
        #expect(starts == 1)
        #expect(monitor.isRecordingActive)
        monitor.handleRemoteKey(key(.keyUp))
        monitor.handleRemoteKey(key(.keyUp))
        #expect(stops == 1)
        #expect(!monitor.isRecordingActive)
    }

    @Test func doesNotStopKeyboardRecordingOrReactToChords() {
        let monitor = HotkeyMonitor()
        var callbacks = 0
        monitor.onKeyDown = { callbacks += 1 }
        monitor.onKeyUp = { callbacks += 1 }
        monitor.isRecordingActive = true
        monitor.handleRemoteKey(key(.keyDown))
        monitor.handleRemoteKey(key(.keyUp))
        #expect(monitor.isRecordingActive)
        monitor.isRecordingActive = false
        monitor.handleRemoteKey(key(.keyDown, flags: .command))
        monitor.handleRemoteKey(key(.keyUp))
        #expect(!monitor.handleRemoteKey(key(.keyDown, code: 36)))
        #expect(callbacks == 0)
    }

    @Test func shutdownReleasesOwnedRecording() {
        let monitor = HotkeyMonitor()
        var stops = 0
        monitor.onKeyUp = { stops += 1 }
        monitor.handleRemoteKey(key(.keyDown))
        monitor.stop()
        monitor.stop()
        #expect(stops == 1)
        #expect(!monitor.isRecordingActive)
    }
}
