import AppKit
import ObjectiveC
import Observation

/// Manages the NSStatusBar menu bar icon and dropdown menu.
final class MenuBarController {
    private var statusItem: NSStatusItem!
    private let appState: AppState
    private var observation: Any?

    private var editKeyMonitor: Any?

    init(appState: AppState) {
        self.appState = appState
        setupStatusItem()
        setupMenu()
        observeState()
    }

    /// Install a local key event monitor so Cmd+C/V/X/A work in modal dialogs.
    /// LSUIElement apps have no Edit menu, so these shortcuts are dead by default.
    private func startEditKeyMonitor() {
        editKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command) else { return event }
            guard let responder = event.window?.firstResponder else { return event }

            switch event.charactersIgnoringModifiers {
            case "v":
                responder.tryToPerform(#selector(NSText.paste(_:)), with: nil)
                return nil
            case "c":
                responder.tryToPerform(#selector(NSText.copy(_:)), with: nil)
                return nil
            case "x":
                responder.tryToPerform(#selector(NSText.cut(_:)), with: nil)
                return nil
            case "a":
                responder.tryToPerform(#selector(NSText.selectAll(_:)), with: nil)
                return nil
            case "z":
                if event.modifierFlags.contains(.shift) {
                    responder.tryToPerform(Selector(("redo:")), with: nil)
                } else {
                    responder.tryToPerform(Selector(("undo:")), with: nil)
                }
                return nil
            default:
                return event
            }
        }
    }

    private func stopEditKeyMonitor() {
        if let monitor = editKeyMonitor {
            NSEvent.removeMonitor(monitor)
            editKeyMonitor = nil
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(for: .idle)
    }

    private func updateIcon(for phase: AppPhase) {
        guard let button = statusItem.button else { return }

        let symbolName: String
        switch phase {
        case .idle:
            symbolName = "mic"
        case .recording:
            symbolName = "mic.fill"
        case .transcribing, .translating, .polishing:
            symbolName = "mic.badge.ellipsis"
        case .done:
            symbolName = "mic.badge.checkmark"
        case .error:
            symbolName = "mic.badge.xmark"
        case .downloading:
            symbolName = "arrow.down.circle"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "VoicePad")?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        button.image = image

        // Red tint when recording
        if case .recording = phase {
            button.contentTintColor = .systemRed
        } else {
            button.contentTintColor = nil
        }
    }

    private func setupMenu() {
        let menu = NSMenu()

        menu.addItem(withTitle: "VoicePad", action: nil, keyEquivalent: "").isEnabled = false

        menu.addItem(.separator())

        let polishItem = NSMenuItem(
            title: "Smart Polish (LLM)",
            action: #selector(togglePolish),
            keyEquivalent: ""
        )
        polishItem.target = self
        polishItem.state = appState.polishEnabled ? .on : .off
        menu.addItem(polishItem)

        let translationItem = NSMenuItem(
            title: "Translation (Coming Soon)",
            action: nil,
            keyEquivalent: ""
        )
        translationItem.isEnabled = false
        menu.addItem(translationItem)

        menu.addItem(.separator())

        let apiKeyItem = NSMenuItem(
            title: "Set API Key...",
            action: #selector(setAPIKey),
            keyEquivalent: ""
        )
        apiKeyItem.target = self
        menu.addItem(apiKeyItem)

        menu.addItem(.separator())

        let historyItem = NSMenuItem(
            title: "History...",
            action: #selector(showHistory),
            keyEquivalent: ""
        )
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit VoicePad",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func togglePolish() {
        appState.polishEnabled.toggle()
        if let menu = statusItem.menu,
           let item = menu.items.first(where: { $0.title == "Smart Polish (LLM)" }) {
            item.state = appState.polishEnabled ? .on : .off
        }
    }

    @objc private func setAPIKey() {
        // Activate the app and start key monitor so Cmd+V works in text fields
        NSApp.activate(ignoringOtherApps: true)
        startEditKeyMonitor()

        // Load existing config to pre-fill fields
        let polisher = LLMPolisher()
        let existingConfig = polisher.loadConfig()

        let alert = NSAlert()
        alert.messageText = "LLM API Configuration"
        alert.informativeText = "Configure API for Smart Polish.\nLeave Base URL empty for official Anthropic API."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 136))

        let keyLabel = NSTextField(labelWithString: "API Key:")
        keyLabel.frame = NSRect(x: 0, y: 112, width: 80, height: 20)
        container.addSubview(keyLabel)

        let keyInput = NSTextField(frame: NSRect(x: 85, y: 110, width: 290, height: 24))
        keyInput.placeholderString = "sk-ant-..."
        if let key = existingConfig.apiKey, !key.isEmpty {
            keyInput.stringValue = key
        }
        container.addSubview(keyInput)

        let urlLabel = NSTextField(labelWithString: "Base URL:")
        urlLabel.frame = NSRect(x: 0, y: 78, width: 80, height: 20)
        container.addSubview(urlLabel)

        let urlInput = NSTextField(frame: NSRect(x: 85, y: 76, width: 290, height: 24))
        urlInput.placeholderString = "https://api.anthropic.com (default)"
        if let url = existingConfig.baseURL, !url.isEmpty {
            urlInput.stringValue = url
        }
        container.addSubview(urlInput)

        let modelLabel = NSTextField(labelWithString: "Model:")
        modelLabel.frame = NSRect(x: 0, y: 44, width: 80, height: 20)
        container.addSubview(modelLabel)

        let modelInput = NSTextField(frame: NSRect(x: 85, y: 42, width: 290, height: 24))
        modelInput.placeholderString = "claude-sonnet-4-20250514 (default)"
        if let model = existingConfig.model, !model.isEmpty {
            modelInput.stringValue = model
        }
        container.addSubview(modelInput)

        // Test button and status label
        let testButton = NSButton(title: "Test Connection", target: nil, action: nil)
        testButton.frame = NSRect(x: 85, y: 6, width: 130, height: 28)
        testButton.bezelStyle = .rounded
        container.addSubview(testButton)

        let statusLabel = NSTextField(labelWithString: "")
        statusLabel.frame = NSRect(x: 220, y: 10, width: 155, height: 20)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.alignment = .left
        container.addSubview(statusLabel)

        testButton.target = self
        testButton.action = #selector(testAPIConnection(_:))
        // Store references via ObjC associated objects for the action handler
        objc_setAssociatedObject(testButton, "keyInput", keyInput, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(testButton, "urlInput", urlInput, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(testButton, "modelInput", modelInput, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(testButton, "statusLabel", statusLabel, .OBJC_ASSOCIATION_RETAIN)

        alert.accessoryView = container
        // Make the key input the first responder so user can type/paste immediately
        alert.window.initialFirstResponder = keyInput

        let response = alert.runModal()
        stopEditKeyMonitor()

        if response == .alertFirstButtonReturn {
            let key = keyInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = urlInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = modelInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            polisher.saveConfig(
                apiKey: key.isEmpty ? nil : key,
                baseURL: url.isEmpty ? nil : url,
                model: model.isEmpty ? nil : model
            )
            vpLog("[MenuBar] API config saved")
        }
    }

    @objc private func testAPIConnection(_ sender: NSButton) {
        guard let keyInput = objc_getAssociatedObject(sender, "keyInput") as? NSTextField,
              let urlInput = objc_getAssociatedObject(sender, "urlInput") as? NSTextField,
              let modelInput = objc_getAssociatedObject(sender, "modelInput") as? NSTextField,
              let statusLabel = objc_getAssociatedObject(sender, "statusLabel") as? NSTextField else { return }

        let key = keyInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            statusLabel.textColor = .systemOrange
            statusLabel.stringValue = "Please enter API Key"
            return
        }

        let url = urlInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        sender.isEnabled = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Testing..."

        Task {
            let polisher = LLMPolisher()
            let error = await polisher.testConnection(
                apiKey: key,
                baseURL: url.isEmpty ? nil : url,
                model: model.isEmpty ? nil : model
            )
            await MainActor.run {
                sender.isEnabled = true
                if let error {
                    statusLabel.textColor = .systemRed
                    statusLabel.stringValue = error
                    statusLabel.toolTip = error
                } else {
                    statusLabel.textColor = .systemGreen
                    statusLabel.stringValue = "Connected!"
                }
            }
        }
    }

    @objc private func showHistory() {
        HistoryPopover.shared.show(relativeTo: statusItem)
    }

    private func observeState() {
        // Use withObservationTracking for @Observable
        func track() {
            withObservationTracking {
                _ = appState.phase
            } onChange: { [weak self] in
                DispatchQueue.main.async {
                    self?.updateIcon(for: self?.appState.phase ?? .idle)
                    track()
                }
            }
        }
        track()
    }
}
