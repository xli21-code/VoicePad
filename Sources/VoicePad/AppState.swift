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
    var recordingDuration: TimeInterval = 0
    var translationEnabled: Bool {
        didSet { UserDefaults.standard.set(translationEnabled, forKey: "translationEnabled") }
    }
    var polishEnabled: Bool {
        didSet { UserDefaults.standard.set(polishEnabled, forKey: "polishEnabled") }
    }
    var audioLevels: [Float] = [] // for waveform visualization
    var polishFailed: Bool = false
    var learnResult: String? // Shown briefly in overlay after learning

    private let audioEngine = AudioEngine()
    private var recognizer: SherpaRecognizer?
    private let hotkeyMonitor = HotkeyMonitor()
    private let textInserter = TextInserter()
    private let modelManager = ModelManager()
    let historyStore = HistoryStore()
    private let textProcessor = TextProcessor()
    private let llmPolisher = LLMPolisher()
    private let correctionLearner = CorrectionLearner()
    private var recordingTimer: Timer?
    private var previousApp: NSRunningApplication?
    private let maxRecordingDuration: TimeInterval = 90
    private var idleTimer: Timer?
    private let sleepAfterIdleDuration: TimeInterval = 30 * 60 // 30 minutes
    private var idleResetTask: Task<Void, Never>?

    /// The last text VoicePad pasted, used for correction learning.
    private(set) var lastPastedText: String?
    /// Timestamp of last paste, for double-tap learn detection.
    private var lastPasteTime: Date?

    // MARK: - Exposed Properties for MenuBar

    /// The frontmost app's bundle identifier (for App Branch context display).
    var currentBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// The configured hotkey keyCode.
    var hotkeyKeyCode: Int { hotkeyMonitor.hotkeyKeyCode }

    /// The selected microphone unique ID, or nil for system default.
    var selectedMicID: String? { audioEngine.selectedMicID }

    /// Available input devices from AudioEngine.
    func availableInputDevices() -> [(id: String, name: String)] {
        audioEngine.availableInputDevices()
    }

    /// Change the hotkey to a different modifier key.
    func setHotkeyKeyCode(_ keyCode: Int) {
        hotkeyMonitor.hotkeyKeyCode = keyCode
    }

    /// Change the input device. Pass nil for system default.
    func setInputDevice(uniqueID: String?) {
        audioEngine.setInputDevice(uniqueID: uniqueID)
    }

    init() {
        translationEnabled = UserDefaults.standard.bool(forKey: "translationEnabled")
        polishEnabled = UserDefaults.standard.bool(forKey: "polishEnabled")
        audioEngine.prepare()
        setupHotkey()
        resetIdleTimer()
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
                guard let self else { return }
                self.startRecording()
                // If startRecording failed (not idle, no recognizer), reset monitor state
                if case .recording = self.phase {
                    // OK, recording started
                } else {
                    self.hotkeyMonitor.isRecordingActive = false
                }
            }
        }
        hotkeyMonitor.onKeyUp = { [weak self] in
            Task { @MainActor in
                self?.stopRecordingAndTranscribe()
            }
        }
        hotkeyMonitor.onLongPress = { [weak self] in
            Task { @MainActor in
                self?.showCorrectionPanel()
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

        // Wake AudioEngine from sleep if needed
        if !wakeIfNeeded() {
            vpLog("[AppState] Failed to wake AudioEngine")
            phase = .error("No microphone found")
            updateOverlay()
            scheduleIdleReset(after: 3)
            return
        }
        resetIdleTimer()

        // Remember which app the user is typing in
        previousApp = NSWorkspace.shared.frontmostApplication

        recordingDuration = 0
        audioLevels = []
        polishFailed = false
        phase = .recording
        updateOverlay()
        vpLog("[AppState] phase set to .recording")

        NSSound(named: "Tink")?.play()

        let started = audioEngine.startRecording { [weak self] _, rmsLevel in
            guard let self else { return }
            Task { @MainActor in
                self.audioLevels.append(rmsLevel)
                if self.audioLevels.count > 48 {
                    self.audioLevels.removeFirst()
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

        // If recording was too short (< 0.3s active recording) or empty:
        // If recent paste exists, treat as "learn" trigger
        let activeDuration = recordingDuration
        vpLog("[AppState] stop: samples=\(samples.count), activeDuration=\(String(format: "%.2f", activeDuration))s")
        if samples.isEmpty || activeDuration < 0.3 {
            if let pasteTime = lastPasteTime,
               Date().timeIntervalSince(pasteTime) < 10,
               lastPastedText != nil {
                vpLog("[AppState] Quick tap after paste — triggering learn")
                learnFromLastCorrection()
            } else {
                vpLog("[AppState] Recording too short or empty, returning to idle")
                phase = .idle
                updateOverlay()
            }
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

            // Load vocabulary terms for LLM prompt injection
            let dictionaryTerms = VocabularyStore.shared.load().terms

            // Resolve App Branch context from the app user was typing in
            let branchPrompt = previousApp.flatMap { app in
                AppBranchStore.shared.resolve(bundleID: app.bundleIdentifier ?? "")?.stylePrompt
            }

            if let polished = await llmPolisher.polish(
                processedText,
                dictionaryTerms: dictionaryTerms,
                appBranchPrompt: branchPrompt
            ) {
                processedText = polished
                // Apply post-LLM corrections (catch LLM alterations)
                processedText = textProcessor.applyPostCorrections(processedText)
            } else {
                vpLog("[AppState] Polish failed, using original text")
                await MainActor.run { polishFailed = true }
            }
        }

        // Translation if enabled (runs after polish)
        if translationEnabled {
            await MainActor.run {
                phase = .translating
                updateOverlay()
            }

            if let translated = await llmPolisher.translate(processedText) {
                processedText = translated
            } else {
                vpLog("[AppState] Translation failed, using original text")
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
            lastPastedText = processedText
            lastPasteTime = Date()
        }

        scheduleIdleReset(after: 1.5)
    }

    // MARK: - Correction Learning

    /// Learn from the user's edits to the last pasted text.
    /// Reads the current text field content via Accessibility API,
    /// diffs against lastPastedText, and adds discovered aliases to vocabulary.
    @MainActor
    func learnFromLastCorrection() {
        guard let original = lastPastedText, !original.isEmpty else {
            vpLog("[AppState] No last paste to learn from")
            phase = .error("No recent paste to learn from")
            updateOverlay()
            scheduleIdleReset(after: 2)
            return
        }

        guard let corrected = correctionLearner.readFocusedTextField() else {
            vpLog("[AppState] Could not read text field")
            phase = .error("Cannot read text field")
            updateOverlay()
            scheduleIdleReset(after: 2)
            return
        }

        // Only diff the relevant portion — the corrected text may have more content
        // Find the original text (or close match) within the corrected text
        let textToCompare: String
        if corrected.contains(original) {
            // Original hasn't been edited at all — nothing to learn
            vpLog("[AppState] Text unchanged, nothing to learn")
            phase = .done("No changes detected")
            updateOverlay()
            scheduleIdleReset(after: 1.5)
            return
        } else if corrected.count < original.count * 3 {
            // Corrected text is reasonably close in length — compare directly
            textToCompare = corrected
        } else {
            // Text field has much more content — try to find the edited region
            // Use the last N characters where N is similar to original length
            let searchRange = min(corrected.count, original.count * 2)
            textToCompare = String(corrected.suffix(searchRange))
        }

        let result = correctionLearner.extractCorrections(original: original, corrected: textToCompare)

        if result.newAliases.isEmpty && result.newTerms.isEmpty {
            vpLog("[AppState] No corrections found in diff")
            phase = .done("No corrections found")
            updateOverlay()
            scheduleIdleReset(after: 1.5)
            return
        }

        let (terms, aliases) = correctionLearner.applyToVocabulary(result)
        let summary = [
            terms > 0 ? "+\(terms) terms" : nil,
            aliases > 0 ? "+\(aliases) aliases" : nil,
        ].compactMap { $0 }.joined(separator: ", ")

        vpLog("[AppState] Learned: \(summary)")
        NSSound(named: "Glass")?.play()
        learnResult = summary
        phase = .done("Learned: \(summary)")
        updateOverlay()
        scheduleIdleReset(after: 2)
    }

    // MARK: - Long-Press Correction

    /// Show editable panel with last transcription for correction.
    @MainActor
    private func showCorrectionPanel() {
        // Phase gate: only allow correction when idle or done
        switch phase {
        case .idle, .done, .error:
            break
        default:
            vpLog("[AppState] Correction blocked — phase is \(phase)")
            return
        }

        guard let original = lastPastedText, !original.isEmpty else {
            vpLog("[AppState] No last paste to correct")
            phase = .error("No recent transcription to correct")
            updateOverlay()
            scheduleIdleReset(after: 2)
            return
        }

        // Remember which app to paste back to
        let targetApp = previousApp

        vpLog("[AppState] Showing correction panel for: '\(original.prefix(50))'")

        CorrectionPanel.shared.show(text: original, confirm: { [weak self] corrected in
            guard let self else { return }
            Task { @MainActor in
                self.applyCorrection(original: original, corrected: corrected, targetApp: targetApp)
            }
        }, cancel: {
            vpLog("[AppState] Correction cancelled")
        })
    }

    /// Apply user's correction: try AX replace + always copy to clipboard as backup.
    @MainActor
    private func applyCorrection(original: String, corrected: String, targetApp: NSRunningApplication?) {
        guard original != corrected else {
            vpLog("[AppState] Text unchanged, nothing to do")
            return
        }

        vpLog("[AppState] Applying correction: '\(original.prefix(30))' → '\(corrected.prefix(30))'")

        // Always put corrected text in clipboard (backup for apps where AX fails)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(corrected, forType: .string)

        // Try AX replace in target app (works in native macOS apps like WeChat, Notes, etc.)
        textInserter.replaceOriginal(original, with: corrected, in: targetApp) { [weak self] in
            guard let self else { return }

            self.lastPastedText = corrected
            self.lastPasteTime = Date()

            // Learn aliases
            let result = self.correctionLearner.extractCorrections(original: original, corrected: corrected)
            if !result.newAliases.isEmpty {
                AliasConfirmPanel.shared.show(aliases: result.newAliases) { [weak self] approved in
                    guard let self, !approved.isEmpty else {
                        vpLog("[AppState] No aliases approved")
                        return
                    }
                    let filtered = CorrectionLearner.LearnResult(newAliases: approved, newTerms: [])
                    let (_, aliases) = self.correctionLearner.applyToVocabulary(filtered)
                    if aliases > 0 {
                        vpLog("[AppState] Correction learned: +\(aliases) aliases")
                        NSSound(named: "Glass")?.play()
                        self.learnResult = "+\(aliases) aliases"
                    }
                }
            }

            self.phase = .done("Corrected (also in clipboard)")
            self.updateOverlay()
            self.scheduleIdleReset(after: 3)
        }
    }

    // MARK: - Sleep / Wake

    private func resetIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: sleepAfterIdleDuration, repeats: false) { [weak self] _ in
            guard let self else { return }
            vpLog("[AppState] Idle for \(Int(self.sleepAfterIdleDuration / 60)) min — putting AudioEngine to sleep")
            self.audioEngine.sleep()
        }
    }

    /// Wake the AudioEngine if it's sleeping or not yet started. Returns true if ready.
    private func wakeIfNeeded() -> Bool {
        // Always check real engine state — macOS can silently kill audio IO
        audioEngine.syncEngineState()

        if audioEngine.isSleeping {
            vpLog("[AppState] Waking AudioEngine from sleep")
            return audioEngine.wake()
        }
        if !audioEngine.engineRunning {
            vpLog("[AppState] AudioEngine not running, attempting prepare")
            audioEngine.prepare()
        }
        return audioEngine.engineRunning
    }

    // MARK: - Helpers

    private func scheduleIdleReset(after seconds: TimeInterval) {
        // Cancel any previous idle reset to avoid race
        idleResetTask?.cancel()
        idleResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if case .idle = phase { return }
            phase = .idle
            updateOverlay()
        }
    }
}
