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

// Debug/regression hook: print the exact system prompt the polisher would send, so the
// evaluation harness measures the shipped prompt instead of a stale copy of it.
if CommandLine.arguments.contains("--dump-polish-prompt") {
    // `--contract <name>` lets the harness check a per-app contract, not just the default.
    let args = CommandLine.arguments
    let contract = args.firstIndex(of: "--contract").flatMap { index -> OutputContract? in
        guard index + 1 < args.count else { return nil }
        return OutputContract(rawValue: args[index + 1])
    } ?? .neutral
    // FileHandle writes are unbuffered; print() would be lost when stdout is a pipe.
    FileHandle.standardOutput.write(Data(LLMPolisher.debugPolishPrompt(contract: contract).utf8))
    exit(0)
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
