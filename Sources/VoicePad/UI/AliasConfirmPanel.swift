import AppKit

/// Confirmation panel shown after correction.
/// Lists alias candidates with checkboxes — user picks which ones to save.
final class AliasConfirmPanel {
    static let shared = AliasConfirmPanel()

    private var panel: NSPanel?
    private var onConfirm: (([Alias]) -> Void)?

    private init() {}

    func show(aliases: [Alias], confirm: @escaping ([Alias]) -> Void) {
        onConfirm = confirm

        // Build the panel fresh each time (alias list varies)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 0),
            styleMask: [.titled, .closable, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.title = "Save to Dictionary?"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: .zero)

        // Hint
        let hint = NSTextField(wrappingLabelWithString: "Select which corrections to remember:")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hint)

        // Checkboxes for each alias
        var checkboxes: [NSButton] = []
        var previousView: NSView = hint

        for (i, alias) in aliases.enumerated() {
            let cb = NSButton(checkboxWithTitle: "\(alias.from)  →  \(alias.to)", target: nil, action: nil)
            cb.state = .on
            cb.tag = i
            cb.font = .systemFont(ofSize: 13)
            cb.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(cb)
            checkboxes.append(cb)

            NSLayoutConstraint.activate([
                cb.topAnchor.constraint(equalTo: previousView.bottomAnchor, constant: i == 0 ? 10 : 6),
                cb.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
                cb.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            ])
            previousView = cb
        }

        // Buttons
        let saveBtn = NSButton(title: "Save Selected", target: nil, action: nil)
        saveBtn.bezelStyle = .rounded
        saveBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(saveBtn)

        let skipBtn = NSButton(title: "Skip All", target: nil, action: nil)
        skipBtn.bezelStyle = .rounded
        skipBtn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(skipBtn)

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            saveBtn.topAnchor.constraint(equalTo: previousView.bottomAnchor, constant: 14),
            saveBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            saveBtn.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            skipBtn.centerYAnchor.constraint(equalTo: saveBtn.centerYAnchor),
            skipBtn.trailingAnchor.constraint(equalTo: saveBtn.leadingAnchor, constant: -8),
        ])

        // Calculate height
        let fittingHeight = 12 + 18 + CGFloat(aliases.count) * 28 + 14 + 30 + 12
        let frame = NSRect(x: 0, y: 0, width: 400, height: max(fittingHeight, 120))
        container.frame = frame
        panel.setContentSize(frame.size)
        panel.contentView = container

        // Position
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.midX - 200
            let y = screen.visibleFrame.midY + 50
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Actions
        saveBtn.target = self
        saveBtn.action = #selector(saveAction)
        skipBtn.target = self
        skipBtn.action = #selector(skipAction)

        self.panel = panel

        // Store checkboxes + aliases for retrieval
        objc_setAssociatedObject(panel, &AssocKeys.checkboxes, checkboxes, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(panel, &AssocKeys.aliases, aliases, .OBJC_ASSOCIATION_RETAIN)

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func saveAction() {
        guard let panel else { return }
        let checkboxes = objc_getAssociatedObject(panel, &AssocKeys.checkboxes) as? [NSButton] ?? []
        let aliases = objc_getAssociatedObject(panel, &AssocKeys.aliases) as? [Alias] ?? []

        let approved = checkboxes.compactMap { cb -> Alias? in
            cb.state == .on ? aliases[cb.tag] : nil
        }

        panel.orderOut(nil)
        self.panel = nil
        onConfirm?(approved)
    }

    @objc private func skipAction() {
        panel?.orderOut(nil)
        panel = nil
        onConfirm?([])
    }
}

private struct AssocKeys {
    static var checkboxes = 0
    static var aliases = 1
}
