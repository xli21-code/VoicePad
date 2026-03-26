import AVFoundation
import Accelerate
import CoreAudio

/// Records audio at 16kHz mono Float32 — the format sherpa-onnx expects.
/// The engine stays running with a permanent tap to eliminate startup latency.
/// A pre-roll ring buffer captures the last 1.5s so no speech is lost on key-down.
final class AudioEngine {
    private var engine: AVAudioEngine?
    private var sampleBuffer: [Float] = []
    private let sampleRate: Double = 16000
    private let bufferSize: AVAudioFrameCount = 1600 // ~100ms at 16kHz
    private let lock = NSLock()

    private var isRecording = false
    private var onChunk: (([Float], Float) -> Void)?
    private var chunkCount = 0
    private var engineRunning = false

    // Pre-roll ring buffer: keeps last 1.5s of converted 16kHz mono samples
    private let preRollLock = NSLock()
    private var preRollBuffer: [Float] = []
    private let preRollMaxSamples: Int = 24000 // 1.5s at 16kHz

    /// Check if a real audio input device is available.
    private func hasInputDevice() -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &size, &deviceID
        )
        let available = status == noErr && deviceID != kAudioObjectUnknown
        vpLog("[AudioEngine] hasInputDevice: \(available) (deviceID=\(deviceID), status=\(status))")
        return available
    }

    /// Convert raw input buffer to 16kHz mono Float32 samples.
    private func convert(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter?,
        desiredFormat: AVAudioFormat,
        targetRate: Double,
        sourceRate: Double
    ) -> [Float]? {
        if let converter {
            let frameCapacity = AVAudioFrameCount(
                Double(buffer.frameLength) * targetRate / sourceRate
            )
            guard frameCapacity > 0 else { return nil }
            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: desiredFormat,
                frameCapacity: frameCapacity
            ) else { return nil }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            if error != nil { return nil }

            let ptr = convertedBuffer.floatChannelData![0]
            return Array(UnsafeBufferPointer(start: ptr, count: Int(convertedBuffer.frameLength)))
        } else {
            let ptr = buffer.floatChannelData![0]
            return Array(UnsafeBufferPointer(start: ptr, count: Int(buffer.frameLength)))
        }
    }

    /// Start the audio engine and install a permanent tap.
    /// Call once at app startup. The engine stays running in the background.
    func prepare() {
        guard hasInputDevice() else {
            vpLog("[AudioEngine] No input device available — skipping engine setup")
            return
        }

        let eng = AVAudioEngine()
        self.engine = eng
        let inputNode = eng.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        vpLog("[AudioEngine] prepare: sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount)")

        guard inputFormat.sampleRate > 0 else {
            vpLog("[AudioEngine] ERROR: sampleRate is 0 — no microphone?")
            return
        }

        guard inputFormat.channelCount > 0 else {
            vpLog("[AudioEngine] ERROR: channelCount is 0 — invalid audio format")
            return
        }

        guard inputNode.numberOfInputs > 0 else {
            vpLog("[AudioEngine] ERROR: inputNode has no inputs — device may have disconnected")
            return
        }

        let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        // Create converter from input format to desired 16kHz mono
        let needsConversion = inputFormat.sampleRate != sampleRate || inputFormat.channelCount != 1
        let converter: AVAudioConverter? = needsConversion
            ? AVAudioConverter(from: inputFormat, to: desiredFormat)
            : nil
        if needsConversion {
            vpLog("[AudioEngine] converter: \(inputFormat.sampleRate)Hz \(inputFormat.channelCount)ch -> 16kHz mono")
        }

        let targetRate = sampleRate
        let sourceRate = inputFormat.sampleRate
        let maxPre = preRollMaxSamples

        // Remove any existing tap to prevent double-tap crash
        inputNode.removeTap(onBus: 0)

        // Install a permanent tap using the input node's native format
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) {
            [weak self] buffer, _ in
            guard let self else { return }

            guard let samples = self.convert(
                buffer: buffer,
                converter: converter,
                desiredFormat: desiredFormat,
                targetRate: targetRate,
                sourceRate: sourceRate
            ) else { return }

            if self.isRecording {
                // Active recording — append to main buffer and notify
                var rms: Float = 0
                vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))

                self.lock.lock()
                self.sampleBuffer.append(contentsOf: samples)
                self.lock.unlock()

                self.chunkCount += 1
                if self.chunkCount <= 3 {
                    vpLog("[AudioEngine] chunk #\(self.chunkCount): \(samples.count) samples, rms=\(rms)")
                }

                self.onChunk?(samples, rms)
            } else {
                // Not recording — feed pre-roll ring buffer
                self.preRollLock.lock()
                self.preRollBuffer.append(contentsOf: samples)
                if self.preRollBuffer.count > maxPre {
                    self.preRollBuffer.removeFirst(self.preRollBuffer.count - maxPre)
                }
                self.preRollLock.unlock()
            }
        }

        do {
            try eng.start()
            engineRunning = true
            vpLog("[AudioEngine] engine started (always-on mode)")
        } catch {
            vpLog("[AudioEngine] FAILED to start engine: \(error)")
        }
    }

    /// Start collecting audio samples. Returns true if engine is running.
    /// Pre-roll audio (~1.5s before key-down) is prepended automatically.
    @discardableResult
    func startRecording(onChunk: @escaping ([Float], Float) -> Void) -> Bool {
        vpLog("[AudioEngine] startRecording called, engineRunning=\(engineRunning)")

        // If engine isn't running yet, try to (re-)prepare — a mic may have been plugged in
        if !engineRunning {
            prepare()
        }

        guard engineRunning else {
            vpLog("[AudioEngine] ERROR: engine not running — no input device?")
            return false
        }

        // Grab pre-roll samples before clearing
        preRollLock.lock()
        let preRoll = preRollBuffer
        preRollBuffer.removeAll()
        preRollLock.unlock()

        lock.lock()
        sampleBuffer = preRoll // seed with pre-roll audio
        lock.unlock()

        vpLog("[AudioEngine] pre-roll: \(preRoll.count) samples (\(String(format: "%.2f", Double(preRoll.count) / sampleRate))s)")

        chunkCount = 0
        self.onChunk = onChunk
        isRecording = true  // Tap starts collecting immediately — no delay

        // Send pre-roll to streaming recognizer as initial chunk
        if !preRoll.isEmpty {
            var rms: Float = 0
            vDSP_rmsqv(preRoll, 1, &rms, vDSP_Length(preRoll.count))
            onChunk(preRoll, rms)
        }

        vpLog("[AudioEngine] recording started (with pre-roll)")
        return true
    }

    /// Stop collecting and return the full sample buffer.
    func stopRecording() -> [Float] {
        isRecording = false
        onChunk = nil

        lock.lock()
        let buffer = sampleBuffer
        sampleBuffer.removeAll()
        lock.unlock()
        vpLog("[AudioEngine] stopped recording, samples=\(buffer.count) (\(String(format: "%.2f", Double(buffer.count) / sampleRate))s)")
        return buffer
    }
}
