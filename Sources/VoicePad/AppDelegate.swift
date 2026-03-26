import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController!
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        vpLog("[VoicePad] App launched")
        menuBarController = MenuBarController(appState: appState)

        // Check accessibility permission (needed for global hotkey + paste)
        let trusted = AXIsProcessTrusted()
        vpLog("[VoicePad] Accessibility trusted: \(trusted)")
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        // Request microphone permission
        Task {
            await appState.requestMicPermission()
            vpLog("[VoicePad] Mic permission done")
        }

        // Ensure ASR model is available
        Task {
            await appState.ensureASRModel()
            vpLog("[VoicePad] ASR model ready: \(appState.phase)")
        }
    }
}
