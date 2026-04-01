import AppKit
import Foundation

// VoicePad — macOS Voice-to-Text Menu Bar App
// Push-to-talk: hold Control to record, release to transcribe and paste.

// Simple file logger for debugging
func vpLog(_ msg: String) {
    let logPath = NSHomeDirectory() + "/.voicepad/voicepad.log"
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: line.data(using: .utf8))
    }
}

vpLog("=== VoicePad Starting ===")

// Prevent multiple instances — activate existing one if already running
let runningInstances = NSRunningApplication.runningApplications(withBundleIdentifier: "com.voicepad.app")
    .filter { $0 != NSRunningApplication.current }
if !runningInstances.isEmpty {
    vpLog("Another VoicePad instance is already running, activating it and exiting")
    runningInstances.first?.activate()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no dock icon
app.run()
