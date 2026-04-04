import SwiftUI

/// Settings tab for API configuration (key, base URL, model).
struct APISettingsView: View {
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var model = VoicePadConfig.defaultModel
    @State private var testStatus: TestStatus = .idle
    @State private var testMessage = ""
    @State private var remoteModels: [String] = []

    private enum TestStatus {
        case idle, testing, success, error
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("API Key") {
                    SecureField("sk-ant-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("Base URL") {
                    TextField("https://api.anthropic.com (default)", text: $baseURL)
                        .textFieldStyle(.roundedBorder)
                }

                LabeledContent("Model") {
                    if remoteModels.isEmpty {
                        Picker("", selection: $model) {
                            ForEach(VoicePadConfig.availableModels, id: \.id) { m in
                                Text(m.label).tag(m.id)
                            }
                        }
                        .labelsHidden()
                    } else {
                        Picker("", selection: $model) {
                            ForEach(remoteModels, id: \.self) { m in
                                Text(m).tag(m)
                            }
                        }
                        .labelsHidden()
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
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || testStatus == .testing)

                    if testStatus == .testing {
                        ProgressView()
                            .controlSize(.small)
                    }

                    switch testStatus {
                    case .success:
                        Label("Connected!", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
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
        .onAppear { loadConfig() }
    }

    private func loadConfig() {
        let config = LLMPolisher().loadConfig()
        apiKey = config.apiKey ?? ""
        baseURL = config.baseURL == VoicePadConfig.defaultBaseURL ? "" : config.baseURL
        model = config.model
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

    private func testConnection() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            testStatus = .error
            testMessage = "Please enter API Key"
            return
        }

        testStatus = .testing
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let polisher = LLMPolisher()

        Task {
            // Fetch models and test connection in parallel
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
                // Update remote models list
                if let models = fetchedModels, !models.isEmpty {
                    remoteModels = models
                    // Auto-select the first model if current model is not in the list
                    if !models.contains(model), let first = models.first {
                        model = first
                        vpLog("[APISettings] Auto-selected model: \(first)")
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
