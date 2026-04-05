import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController!
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        vpLog("[VoicePad] App launched")
        ConfigDirectory.ensureExists()
        VocabularyStore.shared.migrateIfNeeded()
        menuBarController = MenuBarController(appState: appState)

        // Check accessibility permission (needed for global hotkey + paste)
        let trusted = AXIsProcessTrusted()
        vpLog("[VoicePad] Accessibility trusted: \(trusted)")
        if !trusted {
            let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        // Request Automation permission for System Events (needed for AppleScript paste fallback)
        requestAutomationPermission()

        // Pre-warm Accessibility check — if user just granted permission after prompt,
        // CGEvent paste will work immediately on next recording
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let retrust = AXIsProcessTrusted()
            vpLog("[VoicePad] Accessibility re-check: \(retrust)")
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

    /// Trigger a harmless Apple Event to System Events so macOS prompts for Automation permission.
    /// Without this, VoicePad won't appear in System Settings → Privacy → Automation.
    private func requestAutomationPermission() {
        DispatchQueue.global(qos: .utility).async {
            let script = NSAppleScript(source: """
                tell application "System Events" to return name of first process
            """)
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
            if let error {
                vpLog("[VoicePad] Automation permission request: \(error[NSAppleScript.errorBriefMessage] ?? "denied")")
            } else {
                vpLog("[VoicePad] Automation permission granted for System Events")
            }
        }
    }
}
