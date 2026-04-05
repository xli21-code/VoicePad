import AppKit
import Observation

/// Manages the NSStatusBar menu bar icon and dropdown menu.
/// Menu rebuilds via NSMenuDelegate on every open for dynamic content.
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let appState: AppState
    private var observation: Any?

    init(appState: AppState) {
        self.appState = appState
        super.init()
        setupStatusItem()
        setupMenu()
        observeState()
    }

    // MARK: - Status Item

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

        if case .recording = phase {
            button.contentTintColor = .systemRed
        } else {
            button.contentTintColor = nil
        }
    }

    // MARK: - Menu (rebuilt on every open via NSMenuDelegate)

    private func setupMenu() {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // --- Title ---
        menu.addItem(withTitle: "VoicePad", action: nil, keyEquivalent: "").isEnabled = false

        menu.addItem(.separator())

        // --- Daily Toggles ---
        let polishItem = NSMenuItem(title: "Smart Polish (LLM)", action: #selector(togglePolish), keyEquivalent: "")
        polishItem.target = self
        polishItem.state = appState.polishEnabled ? .on : .off
        menu.addItem(polishItem)

        let translationItem = NSMenuItem(title: "Translation (zh↔en)", action: #selector(toggleTranslation), keyEquivalent: "")
        translationItem.target = self
        translationItem.state = appState.translationEnabled ? .on : .off
        if !appState.polishEnabled && !appState.translationEnabled {
            translationItem.isEnabled = LLMPolisher().hasAPIKey()
        }
        menu.addItem(translationItem)

        // --- Context Status ---
        let branchName = AppBranchStore.shared.resolvedName(for: appState.currentBundleID)
        let contextItem = NSMenuItem(title: "Context: \(branchName)", action: nil, keyEquivalent: "")
        contextItem.isEnabled = false
        menu.addItem(contextItem)

        menu.addItem(.separator())

        // --- Config Submenus ---
        let hotkeyName = HotkeyMonitor.nameForKeyCode(appState.hotkeyKeyCode)
        let hotkeyItem = NSMenuItem(title: "Hotkey: Double-tap \(hotkeyName)", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = buildHotkeySubmenu()
        menu.addItem(hotkeyItem)

        let micName = selectedMicName()
        let micItem = NSMenuItem(title: "Microphone (\(micName))", action: nil, keyEquivalent: "")
        micItem.submenu = buildMicSubmenu()
        menu.addItem(micItem)

        // --- Learn ---
        let learnItem = NSMenuItem(title: "Learn from Last Correction", action: #selector(learnCorrection), keyEquivalent: "l")
        learnItem.target = self
        learnItem.isEnabled = appState.lastPastedText != nil
        menu.addItem(learnItem)

        menu.addItem(.separator())

        // --- Settings ---
        let termCount = VocabularyStore.shared.termCount
        let aliasCount = VocabularyStore.shared.aliasCount
        var dictTitle = "Dictionary"
        if termCount > 0 || aliasCount > 0 {
            dictTitle += " (\(termCount) terms, \(aliasCount) aliases)"
        }
        let dictItem = NSMenuItem(title: "\(dictTitle)...", action: #selector(openVocabulary), keyEquivalent: "")
        dictItem.target = self
        menu.addItem(dictItem)

        let branchItem = NSMenuItem(title: "App Contexts...", action: #selector(openAppContexts), keyEquivalent: "")
        branchItem.target = self
        menu.addItem(branchItem)

        let settingsItem = NSMenuItem(title: "API Settings...", action: #selector(openAPISettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        // --- History ---
        let historyItem = NSMenuItem(title: "History...", action: #selector(showHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        menu.addItem(.separator())

        // --- Quit ---
        let quitItem = NSMenuItem(title: "Quit VoicePad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    // MARK: - Hotkey Submenu

    private func buildHotkeySubmenu() -> NSMenu {
        let submenu = NSMenu()
        for option in HotkeyMonitor.hotkeyOptions {
            let item = NSMenuItem(title: option.name, action: #selector(selectHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.tag = option.keyCode
            item.state = option.keyCode == appState.hotkeyKeyCode ? .on : .off
            submenu.addItem(item)
        }
        return submenu
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        appState.setHotkeyKeyCode(sender.tag)
    }

    // MARK: - Microphone Submenu

    private func buildMicSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let autoItem = NSMenuItem(title: "Automatic", action: #selector(selectMic(_:)), keyEquivalent: "")
        autoItem.target = self
        autoItem.representedObject = nil as String?
        autoItem.state = appState.selectedMicID == nil ? .on : .off
        submenu.addItem(autoItem)

        submenu.addItem(.separator())

        let devices = appState.availableInputDevices()
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMic(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id
            item.state = device.id == appState.selectedMicID ? .on : .off
            submenu.addItem(item)
        }

        if devices.isEmpty {
            let noDeviceItem = NSMenuItem(title: "No external devices", action: nil, keyEquivalent: "")
            noDeviceItem.isEnabled = false
            submenu.addItem(noDeviceItem)
        }

        return submenu
    }

    @objc private func selectMic(_ sender: NSMenuItem) {
        let deviceID = sender.representedObject as? String
        appState.setInputDevice(uniqueID: deviceID)
    }

    private func selectedMicName() -> String {
        guard let selectedID = appState.selectedMicID else { return "Automatic" }
        let devices = appState.availableInputDevices()
        if let device = devices.first(where: { $0.id == selectedID }) {
            return device.name
        }
        return "Automatic"
    }

    // MARK: - Toggle Actions

    @objc private func togglePolish() {
        appState.polishEnabled.toggle()
    }

    @objc private func toggleTranslation() {
        appState.translationEnabled.toggle()
    }

    // MARK: - Learn Action

    @objc private func learnCorrection() {
        Task { @MainActor in
            appState.learnFromLastCorrection()
        }
    }

    // MARK: - Settings Window Actions

    @objc private func openVocabulary() {
        SettingsWindowController.shared.showTab(.vocabulary)
    }

    @objc private func openAppContexts() {
        SettingsWindowController.shared.showTab(.appContexts)
    }

    @objc private func openAPISettings() {
        SettingsWindowController.shared.showTab(.api)
    }

    // MARK: - History

    @objc private func showHistory() {
        HistoryPopover.shared.historyStore = appState.historyStore
        HistoryPopover.shared.show(relativeTo: statusItem)
    }

    // MARK: - State Observation

    private func observeState() {
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
