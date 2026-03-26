import AVFoundation
import AppKit
import Observation

enum AppPhase: Equatable {
    case idle
    case recording
    case transcribing
    case polishing
    case translating
    case done(String)
    case error(String)
    case downloading(String, Double) // model name, progress 0-1
}

@Observable
final class AppState {
    var phase: AppPhase = .idle
    var streamingText: String = ""
    var recordingDuration: TimeInterval = 0
    var translationEnabled: Bool {
        didSet { UserDefaults.standard.set(translationEnabled, forKey: "translationEnabled") }
    }
    var polishEnabled: Bool {
        didSet { UserDefaults.standard.set(polishEnabled, forKey: "polishEnabled") }
    }
    var audioLevels: [Float] = [] // for waveform visualization
    var polishFailed: Bool = false

    private let audioEngine = AudioEngine()
    private var recognizer: SherpaRecognizer?
    private let hotkeyMonitor = HotkeyMonitor()
    private let textInserter = TextInserter()
    private let modelManager = ModelManager()
    private let historyStore = HistoryStore()
    private let textProcessor = TextProcessor()
    private let llmPolisher = LLMPolisher()
    private var recordingTimer: Timer?
    private var previousApp: NSRunningApplication?
    private let maxRecordingDuration: TimeInterval = 30

    init() {
        translationEnabled = UserDefaults.standard.bool(forKey: "translationEnabled")
        polishEnabled = UserDefaults.standard.bool(forKey: "polishEnabled")
        audioEngine.prepare()
        setupHotkey()
    }

    /// Call this after every phase change to update the overlay.
    private func updateOverlay() {
        vpLog("[AppState] updateOverlay: phase=\(phase)")
        switch phase {
        case .idle:
            OverlayPanel.shared.hide()
        default:
            OverlayPanel.shared.show(appState: self)
        }
    }

    // MARK: - Permissions

    func requestMicPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            await MainActor.run {
                phase = .error("Grant microphone access in System Settings")
            }
        @unknown default:
            break
        }
    }

    // MARK: - Model Management

    func ensureASRModel() async {
        guard !modelManager.isASRModelReady() else {
            initRecognizer()
            return
        }

        await MainActor.run {
            phase = .downloading("SenseVoice", 0)
        }

        do {
            try await modelManager.downloadASRModel { [weak self] progress in
                Task { @MainActor in
                    self?.phase = .downloading("SenseVoice", progress)
                }
            }
            await MainActor.run {
                phase = .idle
            }
            initRecognizer()
        } catch {
            await MainActor.run {
                phase = .error("Model download failed: \(error.localizedDescription)")
            }
        }
    }

    private func initRecognizer() {
        guard let modelPath = modelManager.asrModelPath() else { return }
        recognizer = SherpaRecognizer(modelDir: modelPath)
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkeyMonitor.onKeyDown = { [weak self] in
            Task { @MainActor in
                self?.startRecording()
            }
        }
        hotkeyMonitor.onKeyUp = { [weak self] in
            Task { @MainActor in
                self?.stopRecordingAndTranscribe()
            }
        }
        hotkeyMonitor.start()
    }

    // MARK: - Recording

    @MainActor
    private func startRecording() {
        vpLog("[AppState] startRecording called, phase=\(phase), recognizer=\(recognizer != nil)")
        guard case .idle = phase else {
            vpLog("[AppState] Not idle, skipping")
            return
        }
        guard recognizer != nil else {
            vpLog("[AppState] No recognizer!")
            phase = .error("Model not loaded")
            updateOverlay()
            scheduleIdleReset(after: 2)
            return
        }

        // Remember which app the user is typing in
        previousApp = NSWorkspace.shared.frontmostApplication

        streamingText = ""
        recordingDuration = 0
        audioLevels = []
        polishFailed = false
        phase = .recording
        updateOverlay()
        vpLog("[AppState] phase set to .recording")

        NSSound(named: "Tink")?.play()

        let started = audioEngine.startRecording { [weak self] samples, rmsLevel in
            guard let self else { return }
            Task { @MainActor in
                self.audioLevels.append(rmsLevel)
                if self.audioLevels.count > 48 {
                    self.audioLevels.removeFirst()
                }

                // Feed to streaming recognizer for partial results
                if let partial = self.recognizer?.feedSamples(samples) {
                    self.streamingText = partial
                }
            }
        }

        if !started {
            phase = .error("No microphone found")
            updateOverlay()
            scheduleIdleReset(after: 3)
            return
        }

        // Auto-stop after max duration
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.recordingDuration += 0.1
                if self.recordingDuration >= self.maxRecordingDuration {
                    self.stopRecordingAndTranscribe()
                }
            }
        }
    }

    @MainActor
    private func stopRecordingAndTranscribe() {
        vpLog("[AppState] stopRecordingAndTranscribe called, phase=\(phase)")
        guard case .recording = phase else {
            vpLog("[AppState] Not recording, skipping stop")
            return
        }

        recordingTimer?.invalidate()
        recordingTimer = nil

        let samples = audioEngine.stopRecording()
        NSSound(named: "Pop")?.play()

        // If recording was too short (< 0.3s active recording) or empty, skip entirely
        let activeDuration = recordingDuration
        vpLog("[AppState] stop: samples=\(samples.count), activeDuration=\(String(format: "%.2f", activeDuration))s")
        guard !samples.isEmpty, activeDuration >= 0.3 else {
            vpLog("[AppState] Recording too short or empty, returning to idle")
            phase = .idle
            updateOverlay()
            return
        }

        phase = .transcribing
        updateOverlay()

        Task {
            await transcribeAndPaste(samples: samples)
        }
    }

    // MARK: - Transcription & Paste

    private func transcribeAndPaste(samples: [Float]) async {
        guard let recognizer else {
            await MainActor.run {
                phase = .error("Recognizer not ready")
                updateOverlay()
            }
            scheduleIdleReset(after: 2)
            return
        }

        // Offline transcription (more accurate than streaming)
        vpLog("[AppState] transcribing \(samples.count) samples...")
        let result = recognizer.transcribe(samples: samples)
        vpLog("[AppState] transcription result: '\(result.text)' lang=\(result.language ?? "nil")")

        guard !result.text.isEmpty else {
            await MainActor.run {
                phase = .error("No speech detected")
                updateOverlay()
            }
            scheduleIdleReset(after: 2)
            return
        }

        var processedText = textProcessor.process(result.text)

        // LLM polish if enabled
        if polishEnabled {
            await MainActor.run {
                phase = .polishing
                updateOverlay()
            }
            if let polished = await llmPolisher.polish(processedText) {
                processedText = polished
            } else {
                vpLog("[AppState] Polish failed, using original text")
                await MainActor.run { polishFailed = true }
            }
        }

        // Save to history
        let entry = TranscriptEntry(
            text: processedText,
            language: result.language,
            duration: Double(samples.count) / 16000.0
        )
        historyStore.append(entry)

        // Paste the text
        await MainActor.run {
            phase = .done(processedText)
            updateOverlay()
            vpLog("[AppState] pasting to app: \(previousApp?.localizedName ?? "nil")")
            textInserter.paste(processedText, to: previousApp)
        }

        scheduleIdleReset(after: 1.5)
    }

    // MARK: - Helpers

    private func scheduleIdleReset(after seconds: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            if case .idle = phase { return }
            phase = .idle
            streamingText = ""
            updateOverlay()
        }
    }
}
