import AppKit
import Observation

/// Floating overlay panel (Spotlight-style, top-center of screen).
/// Shows recording state, streaming text, and results.
final class OverlayPanel {
    static let shared = OverlayPanel()

    private var panel: NSPanel?
    private var contentView: OverlayContentView?
    private var observation: Any?

    private init() {}

    /// Show the overlay and bind to app state.
    func show(appState: AppState) {
        vpLog("[Overlay] show() called, phase=\(appState.phase)")
        if panel == nil {
            createPanel()
        }

        guard let panel, let contentView else {
            vpLog("[Overlay] panel or contentView is nil!")
            return
        }

        contentView.update(appState: appState)
        positionPanel()
        panel.orderFrontRegardless()
        vpLog("[Overlay] panel shown at \(panel.frame)")

        observeState(appState)
    }

    func hide() {
        vpLog("[Overlay] hide()")
        panel?.orderOut(nil)
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 80),
            styleMask: [.nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let contentView = OverlayContentView(frame: panel.contentView!.bounds)
        contentView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(contentView)

        self.panel = panel
        self.contentView = contentView
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        // Bottom-center of screen, ~80pt above dock
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.minY + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func observeState(_ appState: AppState) {
        func track() {
            withObservationTracking {
                _ = appState.phase
                _ = appState.streamingText
                _ = appState.recordingDuration
                _ = appState.audioLevels
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    self?.contentView?.update(appState: appState)

                    // Auto-hide when idle
                    if case .idle = appState.phase {
                        self?.hide()
                    }
                    track()
                }
            }
        }
        track()
    }
}

// MARK: - Content View

private final class OverlayContentView: NSView {
    private let backgroundView: NSVisualEffectView
    private let statusLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let waveformView = WaveformView()

    override init(frame: NSRect) {
        backgroundView = NSVisualEffectView(frame: frame)
        super.init(frame: frame)

        backgroundView.material = .hudWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 12
        backgroundView.layer?.masksToBounds = true
        backgroundView.autoresizingMask = [.width, .height]
        addSubview(backgroundView)

        // Status label (top line: recording indicator, duration)
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.addSubview(statusLabel)

        // Waveform
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.addSubview(waveformView)

        // Text label (streaming/final text)
        textLabel.font = .systemFont(ofSize: 14)
        textLabel.textColor = .labelColor
        textLabel.maximumNumberOfLines = 3
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.addSubview(textLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 16),

            waveformView.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            waveformView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -16),
            waveformView.widthAnchor.constraint(equalToConstant: 120),
            waveformView.heightAnchor.constraint(equalToConstant: 24),

            textLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            textLabel.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 16),
            textLabel.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -16),
            textLabel.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(appState: AppState) {
        switch appState.phase {
        case .recording:
            let seconds = Int(appState.recordingDuration)
            let remaining = Int(90 - appState.recordingDuration)
            let branchName = AppBranchStore.shared.resolvedName(for: appState.currentBundleID)
            let branchSuffix = branchName != "Default" ? " (\(branchName))" : ""
            statusLabel.stringValue = "● \(seconds / 60):\(String(format: "%02d", seconds % 60))\(branchSuffix)"
            statusLabel.textColor = .systemRed
            textLabel.stringValue = "Recording... \(remaining)s remaining"
            waveformView.levels = appState.audioLevels
            waveformView.isHidden = false

        case .transcribing:
            statusLabel.stringValue = "⟳ Transcribing..."
            statusLabel.textColor = .secondaryLabelColor
            textLabel.stringValue = ""
            waveformView.isHidden = true

        case .polishing:
            statusLabel.stringValue = "⟳ Organizing..."
            statusLabel.textColor = .systemPurple
            textLabel.stringValue = ""
            waveformView.isHidden = true

        case .translating:
            statusLabel.stringValue = "⟳ Translating..."
            statusLabel.textColor = .secondaryLabelColor
            waveformView.isHidden = true

        case .done(let text):
            statusLabel.stringValue = appState.polishFailed ? "✓ Pasted (polish skipped)" : "✓ Pasted"
            statusLabel.textColor = appState.polishFailed ? .systemOrange : .systemGreen
            textLabel.stringValue = text
            waveformView.isHidden = true

        case .error(let msg):
            statusLabel.stringValue = "✗ \(msg)"
            statusLabel.textColor = .systemRed
            textLabel.stringValue = ""
            waveformView.isHidden = true

        case .downloading(let name, let progress):
            let pct = Int(progress * 100)
            statusLabel.stringValue = "↓ Downloading \(name)... \(pct)%"
            statusLabel.textColor = .secondaryLabelColor
            textLabel.stringValue = ""
            waveformView.isHidden = true

        case .idle:
            break
        }

        // Resize panel to fit content
        needsLayout = true
    }
}

// MARK: - Waveform View

private final class WaveformView: NSView {
    var levels: [Float] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !levels.isEmpty else { return }

        let barWidth: CGFloat = 2
        let gap: CGFloat = 1
        let maxBars = Int(bounds.width / (barWidth + gap))
        let displayLevels = Array(levels.suffix(maxBars))

        NSColor.systemRed.withAlphaComponent(0.7).setFill()

        for (i, level) in displayLevels.enumerated() {
            let normalizedLevel = CGFloat(min(level * 10, 1.0)) // Amplify for visibility
            let barHeight = max(2, normalizedLevel * bounds.height)
            let x = CGFloat(i) * (barWidth + gap)
            let y = (bounds.height - barHeight) / 2

            let bar = NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: barWidth, height: barHeight),
                xRadius: 1,
                yRadius: 1
            )
            bar.fill()
        }
    }
}
