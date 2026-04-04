import SwiftUI
import UniformTypeIdentifiers

/// Settings tab for managing vocabulary terms and aliases.
struct VocabularySettingsView: View {
    @State private var vocabulary = Vocabulary()
    @State private var newTerm = ""
    @State private var newAliasFrom = ""
    @State private var newAliasTo = ""
    @State private var isImporting = false
    @State private var importError: String?

    var body: some View {
        HSplitView {
            // Terms panel
            VStack(alignment: .leading, spacing: 8) {
                Text("Terms (\(vocabulary.terms.count))")
                    .font(.headline)
                Text("Words the LLM should recognize and correct to.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("Add term...", text: $newTerm)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTerm() }
                    Button("Add") { addTerm() }
                        .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                List {
                    ForEach(Array(vocabulary.terms.enumerated()), id: \.offset) { index, term in
                        Text(term)
                            .contextMenu {
                                Button("Delete") {
                                    vocabulary.terms.remove(at: index)
                                    save()
                                }
                            }
                    }
                    .onDelete { offsets in
                        vocabulary.terms.remove(atOffsets: offsets)
                        save()
                    }
                }
                .listStyle(.bordered)
            }
            .padding()
            .frame(minWidth: 250)

            // Aliases panel
            VStack(alignment: .leading, spacing: 8) {
                Text("Aliases (\(vocabulary.aliases.count))")
                    .font(.headline)
                Text("Deterministic corrections: wrong → right.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 4) {
                    TextField("Wrong", text: $newAliasFrom)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    TextField("Right", text: $newAliasTo)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addAlias() }
                    Button("Add") { addAlias() }
                        .disabled(newAliasFrom.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newAliasTo.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                List {
                    ForEach(Array(vocabulary.aliases.enumerated()), id: \.element.id) { index, alias in
                        HStack {
                            Text(alias.from)
                                .foregroundStyle(.secondary)
                            Image(systemName: "arrow.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(alias.to)
                        }
                        .contextMenu {
                            Button("Delete") {
                                vocabulary.aliases.remove(at: index)
                                save()
                            }
                        }
                    }
                    .onDelete { offsets in
                        vocabulary.aliases.remove(atOffsets: offsets)
                        save()
                    }
                }
                .listStyle(.bordered)
            }
            .padding()
            .frame(minWidth: 250)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Import...") { importVocabulary() }
                Button("Export...") { exportVocabulary() }
                Spacer()
                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                    Text("Importing...")
                        .foregroundStyle(.secondary)
                }
                if let error = importError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .onAppear { vocabulary = VocabularyStore.shared.load() }
    }

    // MARK: - Actions

    private func addTerm() {
        let term = newTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        if !vocabulary.terms.contains(term) {
            vocabulary.terms.append(term)
            save()
        }
        newTerm = ""
    }

    private func addAlias() {
        let from = newAliasFrom.trimmingCharacters(in: .whitespaces)
        let to = newAliasTo.trimmingCharacters(in: .whitespaces)
        guard !from.isEmpty, !to.isEmpty else { return }
        vocabulary.aliases.append(Alias(from: from, to: to))
        save()
        newAliasFrom = ""
        newAliasTo = ""
    }

    private func save() {
        VocabularyStore.shared.save(vocabulary)
    }

    // MARK: - Import / Export

    private func importVocabulary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .json, .commaSeparatedText, .data]
        panel.allowsMultipleSelection = false
        panel.message = "Select a word list or vocabulary file to import"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let data = try? Data(contentsOf: url) else {
            importError = "Could not read file"
            return
        }

        // Check size limit (50KB)
        guard data.count <= 50 * 1024 else {
            importError = "File too large (max 50KB)"
            return
        }

        // Try parsing as ExportBundle first
        if let bundle = try? JSONDecoder().decode(ExportBundle.self, from: data) {
            vocabulary.terms.append(contentsOf: bundle.vocabulary.terms)
            vocabulary.aliases.append(contentsOf: bundle.vocabulary.aliases)
            // Deduplicate terms
            vocabulary.terms = Array(Set(vocabulary.terms))
            save()
            importError = nil
            return
        }

        // Otherwise, send to LLM for parsing
        guard let text = String(data: data, encoding: .utf8) else {
            importError = "Could not read file as text"
            return
        }

        guard LLMPolisher().hasAPIKey() else {
            importError = "API key required for smart import"
            return
        }

        isImporting = true
        importError = nil

        Task {
            do {
                let imported = try await ImportEngine().parseVocabulary(from: text)
                await MainActor.run {
                    vocabulary.terms.append(contentsOf: imported.terms)
                    vocabulary.aliases.append(contentsOf: imported.aliases)
                    vocabulary.terms = Array(Set(vocabulary.terms))
                    save()
                    isImporting = false
                }
            } catch {
                await MainActor.run {
                    importError = "Import failed: \(error.localizedDescription)"
                    isImporting = false
                }
            }
        }
    }

    private func exportVocabulary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "voicepad-vocabulary.json"
        panel.message = "Export vocabulary and app contexts"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let bundle = ImportEngine().exportBundle()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(bundle) {
            try? data.write(to: url)
        }
    }
}
