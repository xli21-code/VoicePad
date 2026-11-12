import AppKit
import AVFoundation
import Foundation
import WhisperKit

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

// Diagnostic hook: transcribe an archived WAV. Exists because "the tail of long dictations
// goes missing" could not be reproduced without replaying the exact recording, and because a
// silent empty window is invisible from inside the app.
if let flag = CommandLine.arguments.firstIndex(of: "--transcribe"), flag + 1 < CommandLine.arguments.count {
    transcribeProbe(path: CommandLine.arguments[flag + 1])
    exit(0)
}

/// Reads a 16 kHz mono WAV and prints the window layout, timing and transcript.
func transcribeProbe(path: String) {
    let samples: [Float]
    do {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else {
            FileHandle.standardError.write(Data("expected 16 kHz mono float PCM at \(path)\n".utf8))
            return
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return }
        samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    } catch {
        FileHandle.standardError.write(Data("cannot read \(path): \(error)\n".utf8))
        return
    }

    let spans = WhisperKitEngine.windows(of: samples).map { range -> String in
        String(format: "%.1f-%.1f(%.1fs)", Double(range.lowerBound) / 16000,
               Double(range.upperBound) / 16000, Double(range.count) / 16000)
    }
    FileHandle.standardError.write(Data("windows: \(spans.joined(separator: "  "))\n".utf8))

    let engine = WhisperKitEngine()
    let done = DispatchSemaphore(value: 0)
    // Detached on purpose: the parent thread blocks below, so the work must not inherit the
    // main actor or the wait would deadlock.
    Task.detached {
        await engine.prepare()
        let started = Date()
        let result = await engine.transcribe(samples: samples, prompt: ASRPrompt.build())
        let text = result?.text ?? ""
        let header = String(format: "%.1fs  %dms  chars=%d\n",
                            Double(samples.count) / 16000,
                            Int(Date().timeIntervalSince(started) * 1000), text.count)
        FileHandle.standardOutput.write(Data((header + text + "\n").utf8))
        done.signal()
    }
    done.wait()
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
