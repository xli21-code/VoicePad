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

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // menu bar only, no dock icon
app.run()
