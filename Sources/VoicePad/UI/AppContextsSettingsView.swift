import SwiftUI

/// Settings tab for managing app context branches.
struct AppContextsSettingsView: View {
    @State private var branches: [Branch] = []
    @State private var selectedBranchID: UUID?
    @State private var showAppPicker = false
    @State private var appScanResults: [AppInfo] = []

    private var selectedBranch: Binding<Branch>? {
        guard let id = selectedBranchID,
              let index = branches.firstIndex(where: { $0.id == id }) else { return nil }
        return $branches[index]
    }

    var body: some View {
        HSplitView {
            // Branch list
            VStack(alignment: .leading, spacing: 8) {
                Text("Branches")
                    .font(.headline)

                List(selection: $selectedBranchID) {
                    ForEach(branches) { branch in
                        HStack {
                            Image(systemName: iconForStyle(branch.style))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(branch.name)
                                Text("\(branch.bundleIDs.count) apps \u{2022} \(branch.style.displayName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(branch.id)
                    }
                }
                .listStyle(.bordered)

                HStack {
                    Button(action: addBranch) {
                        Image(systemName: "plus")
                    }
                    Button(action: deleteBranch) {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedBranchID == nil)
                }
            }
            .padding()
            .frame(minWidth: 200, maxWidth: 240)

            // Branch detail
            if let binding = selectedBranch {
                BranchDetailView(
                    branch: binding,
                    onSave: save,
                    onShowAppPicker: {
                        scanApps()
                        showAppPicker = true
                    }
                )
            } else {
                VStack {
                    Spacer()
                    Text("Select a branch to edit")
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showAppPicker) {
            AppPickerSheet(
                apps: appScanResults,
                existingBundleIDs: selectedBranch?.wrappedValue.bundleIDs ?? [],
                onAdd: { bundleIDs in
                    guard var branch = selectedBranch?.wrappedValue else { return }
                    branch.bundleIDs.append(contentsOf: bundleIDs)
                    selectedBranch?.wrappedValue = branch
                    save()
                }
            )
        }
        .onAppear { branches = AppBranchStore.shared.loadBranches() }
    }

    private func addBranch() {
        let branch = Branch(name: "New Branch", bundleIDs: [], style: .custom)
        branches.append(branch)
        selectedBranchID = branch.id
        save()
    }

    private func deleteBranch() {
        guard let id = selectedBranchID else { return }
        branches.removeAll { $0.id == id }
        selectedBranchID = branches.first?.id
        save()
    }

    private func save() {
        AppBranchStore.shared.saveBranches(branches)
    }

    private func scanApps() {
        // Scan on background, but for simplicity scan synchronously (fast enough for /Applications)
        appScanResults = AppScanner().scanInstalledApps()
    }

    private func iconForStyle(_ style: BranchStyle) -> String {
        switch style {
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .chat: "bubble.left.and.bubble.right"
        case .formal: "envelope"
        case .academic: "graduationcap"
        case .custom: "gearshape"
        }
    }
}

// MARK: - Branch Detail

private struct BranchDetailView: View {
    @Binding var branch: Branch
    let onSave: () -> Void
    let onShowAppPicker: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Name
            LabeledContent("Name") {
                TextField("Branch name", text: $branch.name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: branch.name) { _, _ in onSave() }
            }

            // Style
            LabeledContent("Style") {
                Picker("", selection: $branch.style) {
                    ForEach(BranchStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .labelsHidden()
                .onChange(of: branch.style) { _, _ in onSave() }
            }

            // Custom prompt (only when style == .custom)
            if branch.style == .custom {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom Prompt")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { branch.customPrompt ?? "" },
                        set: { branch.customPrompt = $0; onSave() }
                    ))
                    .font(.body)
                    .frame(height: 80)
                    .border(Color.secondary.opacity(0.3))
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Prompt Preview")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(branch.style.builtInPrompt)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(6)
                }
            }

            // Apps
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Apps (\(branch.bundleIDs.count))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add App...") { onShowAppPicker() }
                        .controlSize(.small)
                }

                if branch.bundleIDs.isEmpty {
                    Text("No apps assigned")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding()
                } else {
                    List {
                        ForEach(branch.bundleIDs, id: \.self) { bundleID in
                            HStack {
                                appIcon(for: bundleID)
                                    .resizable()
                                    .frame(width: 20, height: 20)
                                Text(appName(for: bundleID))
                                Spacer()
                                Button(action: {
                                    branch.bundleIDs.removeAll { $0 == bundleID }
                                    onSave()
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(.bordered)
                }
            }

            Spacer()
        }
        .padding()
    }

    private func appIcon(for bundleID: String) -> Image {
        if let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: path))
        }
        return Image(systemName: "app")
    }

    private func appName(for bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url) {
            return bundle.infoDictionary?["CFBundleName"] as? String
                ?? bundle.infoDictionary?["CFBundleDisplayName"] as? String
                ?? bundleID
        }
        return bundleID
    }
}

// MARK: - App Picker Sheet

private struct AppPickerSheet: View {
    let apps: [AppInfo]
    let existingBundleIDs: [String]
    let onAdd: ([String]) -> Void

    @State private var searchText = ""
    @State private var selected = Set<String>()
    @Environment(\.dismiss) private var dismiss

    private var filteredApps: [AppInfo] {
        let available = apps.filter { !existingBundleIDs.contains($0.bundleID) }
        if searchText.isEmpty { return available }
        return available.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
            || $0.bundleID.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select Apps")
                    .font(.headline)
                Spacer()
                TextField("Search...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            .padding()

            // App list
            List(filteredApps, selection: $selected) { app in
                HStack {
                    Image(nsImage: app.icon)
                        .resizable()
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading) {
                        Text(app.name)
                        Text(app.bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(app.bundleID)
            }
            .listStyle(.bordered)

            // Actions
            HStack {
                Text("\(selected.count) selected")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    onAdd(Array(selected))
                    dismiss()
                }
                .disabled(selected.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400, height: 500)
    }
}
