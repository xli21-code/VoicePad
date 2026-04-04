import AppKit
import SwiftUI

/// Hosts the SwiftUI Settings view in an NSWindow.
/// Singleton — one Settings window for the app.
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    enum Tab: Int {
        case vocabulary
        case appContexts
        case api
    }

    /// The currently selected tab, bound to SwiftUI.
    private let selectedTab = SelectedTab()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "VoicePad Settings"
        window.center()
        window.isReleasedWhenClosed = false

        super.init(window: window)

        let hostingView = NSHostingController(rootView: SettingsView(selectedTab: selectedTab))
        window.contentViewController = hostingView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showTab(_ tab: Tab) {
        selectedTab.current = tab
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
    }
}

/// Observable object to bridge tab selection between AppKit and SwiftUI.
@Observable
final class SelectedTab {
    var current: SettingsWindowController.Tab = .vocabulary
}
