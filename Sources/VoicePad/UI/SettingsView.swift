import SwiftUI

/// Top-level Settings view with three tabs.
struct SettingsView: View {
    @Bindable var selectedTab: SelectedTab

    var body: some View {
        TabView(selection: $selectedTab.current) {
            VocabularySettingsView()
                .tabItem { Label("Dictionary", systemImage: "text.book.closed") }
                .tag(SettingsWindowController.Tab.vocabulary)

            AppContextsSettingsView()
                .tabItem { Label("App Contexts", systemImage: "app.badge.checkmark") }
                .tag(SettingsWindowController.Tab.appContexts)

            APISettingsView()
                .tabItem { Label("API", systemImage: "network") }
                .tag(SettingsWindowController.Tab.api)
        }
        .frame(minWidth: 600, minHeight: 480)
    }
}
