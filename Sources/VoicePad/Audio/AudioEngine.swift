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
    private(set) var engineRunning = false
    private(set) var isSleeping = false

    // CoreAudio device-change listener
    private var deviceChangeListenerInstalled = false

    // Pre-roll ring buffer: keeps last 1.5s of converted 16kHz mono samples
    private let preRollLock = NSLock()
    private var preRollBuffer: [Float] = []
    private let preRollMaxSamples: Int = 24000 // 1.5s at 16kHz

    // MARK: - Microphone Selection

    /// Returns list of available input audio devices: (uniqueID, name).
    func availableInputDevices() -> [(id: String, name: String)] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &size)

        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &size, &deviceIDs)

        var results: [(id: String, name: String)] = []
        for deviceID in deviceIDs {
            // Check if device has input channels
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var bufferListSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &bufferListSize) == noErr else { continue }

            let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: 1)
            defer { bufferListPointer.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &inputAddress, 0, nil, &bufferListSize, bufferListPointer) == noErr else { continue }

            let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
            let inputChannels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
            guard inputChannels > 0 else { continue }

            // Get device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)

            // Get device UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)

            results.append((id: uid as String, name: name as String))
        }
        return results
    }

    /// Set the input device by unique ID. Pass nil for system default.
    /// Re-prepares the engine with the new device.
    func setInputDevice(uniqueID: String?) {
        if let uniqueID {
            UserDefaults.standard.set(uniqueID, forKey: "selectedMicID")
        } else {
            UserDefaults.standard.removeObject(forKey: "selectedMicID")
        }

        // Apply the device selection
        applyDeviceSelection(uniqueID: uniqueID)

        // Re-prepare with new device
        if engineRunning {
            engine?.stop()
            engineRunning = false
            engine?.inputNode.removeTap(onBus: 0)
            engine = nil
            prepare()
        }
    }

    /// The currently selected mic unique ID, or nil for system default.
    var selectedMicID: String? {
        UserDefaults.standard.string(forKey: "selectedMicID")
    }

    /// Apply the stored device selection to the audio engine.
    private func applyDeviceSelection(uniqueID: String?) {
        guard let uniqueID else { return }

        // Find the AudioDeviceID for this uniqueID
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &size)

        let deviceCount = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &size, &deviceIDs)

        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid)

            if uid as String == uniqueID {
                // Set this device as the default input for our audio unit
                var mutableDeviceID = deviceID
                var inputAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyDefaultInputDevice,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                AudioObjectSetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &inputAddress,
                    0, nil,
                    UInt32(MemoryLayout<AudioDeviceID>.size),
                    &mutableDeviceID
                )
                vpLog("[AudioEngine] Set input device to \(uniqueID) (deviceID=\(deviceID))")
                return
            }
        }
        vpLog("[AudioEngine] Device \(uniqueID) not found — using system default")
    }

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
        installDeviceChangeListener()

        guard hasInputDevice() else {
            vpLog("[AudioEngine] No input device available — skipping engine setup")
            return
        }

        // Clean up old engine before creating a new one
        if let oldEngine = engine {
            vpLog("[AudioEngine] Cleaning up previous engine before re-prepare")
            oldEngine.inputNode.removeTap(onBus: 0)
            oldEngine.stop()
            engine = nil
            engineRunning = false
        }

        // Apply stored mic selection before creating engine
        if let storedMic = selectedMicID {
            applyDeviceSelection(uniqueID: storedMic)
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
            eng.inputNode.removeTap(onBus: 0)
            eng.stop()
            engine = nil
            engineRunning = false
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

    /// Put the engine to sleep — stops the audio engine and releases resources.
    /// Call `wake()` or `prepare()` to restart.
    func sleep() {
        guard engineRunning else { return }
        vpLog("[AudioEngine] going to sleep — stopping engine to save resources")
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        engineRunning = false
        isSleeping = true

        preRollLock.lock()
        preRollBuffer.removeAll()
        preRollLock.unlock()
    }

    /// Wake the engine from sleep. Returns true if successfully restarted.
    @discardableResult
    func wake() -> Bool {
        guard isSleeping else { return engineRunning }
        vpLog("[AudioEngine] waking up from sleep")
        isSleeping = false
        prepare()
        return engineRunning
    }

    // MARK: - Device Change Listener

    /// Install a CoreAudio listener that auto-prepares when an input device appears.
    func installDeviceChangeListener() {
        guard !deviceChangeListenerInstalled else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in
            guard let self else { return }
            vpLog("[AudioEngine] Default input device changed")
            if !self.engineRunning && !self.isRecording {
                vpLog("[AudioEngine] Attempting auto-prepare after device change")
                self.isSleeping = false
                self.prepare()
            }
        }

        if status == noErr {
            deviceChangeListenerInstalled = true
            vpLog("[AudioEngine] Device change listener installed")
        } else {
            vpLog("[AudioEngine] Failed to install device change listener: \(status)")
        }
        _ = selfPtr // suppress unused warning
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
