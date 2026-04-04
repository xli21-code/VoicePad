import AppKit

/// Floating panel for correcting the last transcription.
/// Shows an editable text field pre-filled with the last pasted text.
/// Enter confirms (re-paste + learn), Escape cancels.
final class CorrectionPanel {
    static let shared = CorrectionPanel()

    private var panel: NSPanel?
    private var textView: NSTextView?
    private var onConfirm: ((String) -> Void)?
    private var onCancel: (() -> Void)?
    private var keyMonitor: Any?

    private init() {}

    /// Show the correction panel with the given text.
    func show(text: String, confirm: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        onConfirm = confirm
        onCancel = cancel

        if panel == nil {
            createPanel()
        }

        guard let panel, let textView else { return }

        textView.string = text
        textView.selectAll(nil)
        positionPanel()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        NSApp.activate(ignoringOtherApps: true)

        installKeyMonitor()
    }

    func hide() {
        removeKeyMonitor()
        panel?.orderOut(nil)
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Panel Setup

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 120),
            styleMask: [.titled, .closable, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.title = "Correct Transcription"
        panel.level = .floating
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Container view
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 120))

        // Hint label
        let hint = NSTextField(labelWithString: "Edit and press Enter to re-paste, Escape to cancel")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hint)

        // Scrollable text view
        let scrollView = NSScrollView(frame: .zero)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 488, height: 60))
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true

        scrollView.documentView = textView
        container.addSubview(scrollView)

        // Buttons
        let confirmBtn = NSButton(title: "Confirm ⏎", target: self, action: #selector(confirmAction))
        confirmBtn.bezelStyle = .rounded
        confirmBtn.keyEquivalent = ""  // Enter handled by key monitor
        confirmBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(confirmBtn)

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cancelBtn)

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            scrollView.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            confirmBtn.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            confirmBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            confirmBtn.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),

            cancelBtn.centerYAnchor.constraint(equalTo: confirmBtn.centerYAnchor),
            cancelBtn.trailingAnchor.constraint(equalTo: confirmBtn.leadingAnchor, constant: -8),
        ])

        panel.contentView = container
        self.panel = panel
        self.textView = textView
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panel.frame.width / 2
        let y = screenFrame.midY - panel.frame.height / 2 + 100
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Key Handling

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return event }

            if event.keyCode == 36 && !event.modifierFlags.contains(.shift) {
                // Enter (not Shift+Enter) → confirm
                self.confirmAction()
                return nil
            } else if event.keyCode == 53 {
                // Escape → cancel
                self.cancelAction()
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    // MARK: - Actions

    @objc private func confirmAction() {
        guard let corrected = textView?.string, !corrected.isEmpty else {
            cancelAction()
            return
        }
        hide()
        onConfirm?(corrected)
    }

    @objc private func cancelAction() {
        hide()
        onCancel?()
    }
}
