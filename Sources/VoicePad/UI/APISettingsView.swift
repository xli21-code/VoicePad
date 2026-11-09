import SwiftUI

/// Settings tab for API configuration (key, base URL, model).
struct APISettingsView: View {
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var model = VoicePadConfig.defaultModel
    @State private var testStatus: TestStatus = .idle
    @State private var testMessage = ""
    @State private var remoteModels: [RemoteModel] = []
    @State private var profiles: [APIProfile] = []
    @State private var selectedProfile = ""

    private enum TestStatus {
        case idle, testing, success, error
    }

    var body: some View {
        Form {
            // Saved Profiles
            if !profiles.isEmpty {
                Section {
                    ForEach(profiles) { profile in
                        HStack {
                            Button {
                                applyProfile(profile)
                            } label: {
                                HStack {
                                    Image(systemName: selectedProfile == profile.name ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedProfile == profile.name ? .green : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(profile.name).fontWeight(.medium)
                                        Text(profile.model)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button(role: .destructive) {
                                deleteProfile(profile)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("Saved Profiles")
                        .font(.headline)
                }
            }

            Section {
                LabeledContent("API Key") {
                    HStack(spacing: 6) {
                        SecureField("sk-ant-...", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            if let str = NSPasteboard.general.string(forType: .string) {
                                apiKey = str.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .help("Paste from clipboard")
                    }
                }

                LabeledContent("Base URL") {
                    TextField("https://api.anthropic.com (default)", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("Model") {
                    VStack(alignment: .leading, spacing: 6) {
                        if remoteModels.isEmpty {
                            Picker("", selection: $model) {
                                ForEach(VoicePadConfig.availableModels, id: \.id) { m in
                                    Text(m.label).tag(m.id)
                                }
                            }
                            .labelsHidden()
                        } else {
                            Picker("", selection: $model) {
                                ForEach(remoteModelGroups, id: \.owner) { group in
                                    Section(group.owner.isEmpty ? "Other" : group.owner) {
                                        ForEach(group.models) { m in
                                            Text(m.displayName ?? m.id).tag(m.id)
                                        }
                                    }
                                }
                            }
                            .labelsHidden()
                        }

                        TextField("or type a model id", text: $model)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption.monospaced())
                    }
                }
            } header: {
                Text("LLM API Configuration")
                    .font(.headline)
            } footer: {
                Text("Configure the Claude API for Smart Polish and vocabulary import.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Test Connection") { testConnection() }
                        .disabled((apiKey.trimmingCharacters(in: .whitespaces).isEmpty && !isLocalEndpoint) || testStatus == .testing)

                    if testStatus == .testing {
                        ProgressView()
                            .controlSize(.small)
                    }

                    switch testStatus {
                    case .success:
                        Label("Connected!", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button("Save Profile") { saveCurrentAsProfile() }
                    case .error:
                        Label(testMessage, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .lineLimit(2)
                    default:
                        EmptyView()
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Save") { saveConfig() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear { loadConfig(); loadProfiles() }
    }

    private func loadConfig() {
        let config = LLMPolisher().loadConfig()
        apiKey = config.apiKey ?? ""
        baseURL = config.baseURL == VoicePadConfig.defaultBaseURL ? "" : config.baseURL
        model = config.model
    }

    private var effectiveBaseURL: String {
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return url.isEmpty ? VoicePadConfig.defaultBaseURL : url
    }

    private var isLocalEndpoint: Bool {
        VoicePadConfig.isLocalHost(effectiveBaseURL)
    }

    private struct RemoteModelGroup: Identifiable {
        let owner: String
        let models: [RemoteModel]
        var id: String { owner }
    }

    /// Fetched models are already sorted by owned_by then id; group them for the picker.
    private var remoteModelGroups: [RemoteModelGroup] {
        var groups: [RemoteModelGroup] = []
        for remote in remoteModels {
            if let idx = groups.firstIndex(where: { $0.owner == remote.ownedBy }) {
                groups[idx] = RemoteModelGroup(owner: groups[idx].owner, models: groups[idx].models + [remote])
            } else {
                groups.append(RemoteModelGroup(owner: remote.ownedBy, models: [remote]))
            }
        }
        return groups
    }

    private func loadProfiles() {
        profiles = LLMPolisher().loadProfiles()
    }

    private func saveConfig() {
        let polisher = LLMPolisher()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        polisher.saveConfig(
            apiKey: key.isEmpty ? nil : key,
            baseURL: url.isEmpty ? nil : url,
            model: model
        )
        vpLog("[APISettings] Config saved")
    }

    private func applyProfile(_ profile: APIProfile) {
        apiKey = profile.apiKey
        baseURL = profile.baseURL == VoicePadConfig.defaultBaseURL ? "" : profile.baseURL
        model = profile.model
        selectedProfile = profile.name
        testStatus = .idle
        remoteModels = []
        saveConfig()
    }

    private func saveCurrentAsProfile() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveURL = url.isEmpty ? VoicePadConfig.defaultBaseURL : url
        // Auto-generate name from host + model
        let host = URL(string: effectiveURL)?.host ?? effectiveURL
        let shortModel = model.components(separatedBy: "-").prefix(3).joined(separator: "-")
        let name = "\(host) / \(shortModel)"
        let profile = APIProfile(name: name, apiKey: key, baseURL: effectiveURL, model: model)
        LLMPolisher().saveProfile(profile)
        selectedProfile = name
        loadProfiles()
        saveConfig()
    }

    private func deleteProfile(_ profile: APIProfile) {
        LLMPolisher().deleteProfile(named: profile.name)
        if selectedProfile == profile.name { selectedProfile = "" }
        loadProfiles()
    }

    private func testConnection() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty || isLocalEndpoint else {
            testStatus = .error
            testMessage = "Please enter API Key"
            return
        }

        testStatus = .testing
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let polisher = LLMPolisher()

        Task {
            async let modelsTask = polisher.fetchModels(
                apiKey: key,
                baseURL: url.isEmpty ? nil : url
            )
            async let testTask = polisher.testConnection(
                apiKey: key,
                baseURL: url.isEmpty ? nil : url,
                model: model
            )

            let fetchedModels = await modelsTask
            let error = await testTask

            await MainActor.run {
                if let models = fetchedModels, !models.isEmpty {
                    remoteModels = models
                    if !models.contains(where: { $0.id == model }), let first = models.first {
                        model = first.id
                        vpLog("[APISettings] Auto-selected model: \(first.id)")
                    }
                }

                if let error {
                    testStatus = .error
                    testMessage = error
                } else {
                    testStatus = .success
                    testMessage = remoteModels.isEmpty ? "" : "\(remoteModels.count) models available"
                }
            }
        }
    }
}
