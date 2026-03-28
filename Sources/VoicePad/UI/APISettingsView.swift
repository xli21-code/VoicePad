import SwiftUI

/// Settings tab for API configuration (key, base URL, model).
struct APISettingsView: View {
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var model = ""
    @State private var testStatus: TestStatus = .idle
    @State private var testMessage = ""

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
                    TextField("\(VoicePadConfig.defaultModel) (default)", text: $model)
                        .textFieldStyle(.roundedBorder)
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
        model = config.model == VoicePadConfig.defaultModel ? "" : config.model
    }

    private func saveConfig() {
        let polisher = LLMPolisher()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let mdl = model.trimmingCharacters(in: .whitespacesAndNewlines)
        polisher.saveConfig(
            apiKey: key.isEmpty ? nil : key,
            baseURL: url.isEmpty ? nil : url,
            model: mdl.isEmpty ? nil : mdl
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
        let mdl = model.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            let error = await LLMPolisher().testConnection(
                apiKey: key,
                baseURL: url.isEmpty ? nil : url,
                model: mdl.isEmpty ? nil : mdl
            )
            await MainActor.run {
                if let error {
                    testStatus = .error
                    testMessage = error
                } else {
                    testStatus = .success
                    testMessage = ""
                }
            }
        }
    }
}
