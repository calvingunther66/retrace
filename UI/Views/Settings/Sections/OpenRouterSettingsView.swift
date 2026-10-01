import SwiftUI
import Shared
import Search

public struct OpenRouterSettingsView: View {
    @AppStorage("openRouterEnabled", store: settingsStore) private var isEnabled: Bool = false
    @AppStorage(OpenRouterCredentialsManager.selectedModelDefaultsKey, store: settingsStore) private var selectedModel: String = "anthropic/claude-3.5-sonnet"
    @AppStorage(OpenRouterCredentialsManager.maxContextFramesDefaultsKey, store: settingsStore) private var maxContextFrames: Double = 25
    @AppStorage("openRouterTemperature", store: settingsStore) private var temperature: Double = 0.2

    @AppStorage(OpenRouterCredentialsManager.semanticIndexingEnabledDefaultsKey, store: settingsStore) private var isSemanticIndexingEnabled: Bool = false
    @AppStorage(OpenRouterCredentialsManager.indexingModelDefaultsKey, store: settingsStore) private var indexingModel: String = OpenRouterCredentialsManager.defaultIndexingModel
    @State private var customIndexingModelInput: String = ""
    @State private var isCustomIndexingModel: Bool = false
    // Same sentinel-decoupling fix as `selectedModelPickerTag` above.
    @State private var indexingModelPickerTag: String = ""
    @State private var isRestartingIndexing: Bool = false
    @State private var restartStatusMessage: String? = nil

    @State private var apiKeyInput: String = ""
    @State private var hasStoredKey: Bool = false
    @State private var isShowingKey: Bool = false
    @State private var isTestingConnection: Bool = false
    @State private var testStatusMessage: String? = nil
    @State private var testStatusIsError: Bool = false
    @State private var customModelInput: String = ""
    @State private var isCustomModel: Bool = false
    // Drives the Picker's `selection` — deliberately NOT the same storage as `selectedModel`.
    // Binding the Picker directly to the @AppStorage value meant selecting "Custom Model..."
    // wrote the literal sentinel string "custom" straight into the stored model slug (and if
    // the user closed Settings before clicking Apply, "custom" would be sent to OpenRouter
    // verbatim on every request). It also meant that once Apply *did* write a real custom slug,
    // the Picker's selection matched no tag and rendered blank on reopen. This sentinel is
    // local UI state only; `selectedModel` is written to exactly once, by Apply.
    @State private var selectedModelPickerTag: String = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header Card
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.retraceAccentWash)
                            .frame(width: 40, height: 40)
                        RetraceSymbol("sparkles", size: 18, weight: .semibold)
                            .foregroundColor(.retraceAccent)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenRouter & AI Search")
                            .font(.retraceTitle2)
                            .foregroundColor(.retraceInk)
                        Text("Granular AI search, natural language queries, and timeline Q&A with any LLM")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)
                    }
                }
            }
            .padding(.bottom, 4)

            // Master Enable Toggle
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable AI Granular Search")
                            .font(.retraceBodyMedium)
                            .foregroundColor(.retracePrimary)
                        Text("Synthesize answers across screen history using OpenRouter models")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)
                    }

                    Spacer(minLength: 12)

                    Toggle("", isOn: $isEnabled)
                        .labelsHidden()
                        .toggleStyle(RetraceSwitchStyle())
                        .accessibilityLabel("Enable AI Granular Search")
                }
            }
            .retraceCard()

            // API Key Section
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("API Configuration")
                        .font(.retraceHeadline)
                        .foregroundColor(.retracePrimary)
                    Spacer()
                    Button(action: {
                        if let url = URL(string: "https://openrouter.ai/keys") {
                            NSWorkspace.shared.open(url)
                        }
                    }) {
                        HStack(spacing: 4) {
                            Text("Get API Key")
                                .font(.retraceCaptionMedium)
                            RetraceSymbol("arrow.up.right", size: 10, label: "")
                        }
                        .foregroundColor(.retraceAccent)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("OpenRouter API Key")
                        .font(.retraceMeta)
                        .foregroundColor(.retraceMuted)

                    HStack(spacing: 8) {
                        if isShowingKey {
                            TextField("sk-or-v1-...", text: $apiKeyInput)
                                .textFieldStyle(.plain)
                                .font(.retraceMono)
                                .foregroundColor(.retraceInk)
                                .padding(10)
                                .background(Color.retraceSurface)
                                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous).stroke(Color.retraceBorderStrong, lineWidth: 1))
                                .onSubmit {
                                    saveKey()
                                }
                        } else {
                            SecureField(hasStoredKey ? "••••••••••••••••••••••••••••••••" : "sk-or-v1-...", text: $apiKeyInput)
                                .textFieldStyle(.plain)
                                .font(.retraceMono)
                                .foregroundColor(.retraceInk)
                                .padding(10)
                                .background(Color.retraceSurface)
                                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous).stroke(Color.retraceBorderStrong, lineWidth: 1))
                                .onSubmit {
                                    saveKey()
                                }
                        }

                        Button(action: toggleKeyVisibility) {
                            RetraceSymbol(isShowingKey ? "eye.slash" : "eye", size: 13)
                                .foregroundColor(.retraceSecondary)
                                .frame(width: 36, height: 36)
                                .background(Color.retraceSurface)
                                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous).stroke(Color.retraceBorderStrong, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isShowingKey ? "Hide API key" : "Show API key")
                        .help(isShowingKey ? "Hide API key" : "Show API key")

                        if hasStoredKey || !apiKeyInput.isEmpty {
                            Button(action: copyKey) {
                                RetraceSymbol("doc.on.doc", size: 13)
                                    .foregroundColor(.retraceSecondary)
                                    .frame(width: 36, height: 36)
                                    .background(Color.retraceSurface)
                                    .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous).stroke(Color.retraceBorderStrong, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Copy API key")
                            .help("Copy API key to clipboard")
                        }

                        Button(action: saveKey) {
                            Text("Save")
                        }
                        .buttonStyle(RetraceButtonStyle(.primary))
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if hasStoredKey {
                            Button(action: deleteKey) {
                                RetraceSymbol("trash", size: 13)
                                    .foregroundColor(.retraceCritical.opacity(0.8))
                                    .frame(width: 36, height: 36)
                                    .background(Color.retraceSurface)
                                    .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous).stroke(Color.retraceBorderStrong, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Delete API key")
                            .help("Delete API key from Keychain")
                        }
                    }

                    if hasStoredKey {
                        HStack(spacing: 6) {
                            RetraceSymbol("checkmark.shield.fill", size: 11)
                                .foregroundColor(.retraceGood)
                            Text("API Key is securely saved in macOS Keychain")
                                .font(.retraceMeta)
                                .foregroundColor(.retraceMuted)
                        }
                        .padding(.top, 2)
                    }
                }

                // Test Connection Button
                HStack(spacing: 12) {
                    Button(action: testConnection) {
                        HStack(spacing: 6) {
                            if isTestingConnection {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .frame(width: 14, height: 14)
                            } else {
                                RetraceSymbol("bolt.horizontal.fill", size: 11)
                            }
                            Text("Test API Connection")
                        }
                    }
                    .buttonStyle(RetraceButtonStyle(.secondary))
                    .disabled(isTestingConnection || (!hasStoredKey && apiKeyInput.isEmpty))

                    if let message = testStatusMessage {
                        HStack(spacing: 6) {
                            RetraceSymbol(testStatusIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill", size: 13)
                                .foregroundColor(testStatusIsError ? .retraceWarningText : .retraceGood)
                            Text(message)
                                .font(.retraceCaption)
                                .foregroundColor(.retracePrimary)
                        }
                    }
                }
            }
            .retraceCard()

            // Model Selection
            VStack(alignment: .leading, spacing: 16) {
                Text("Model Selection")
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Selected Model")
                        .font(.retraceMeta)
                        .foregroundColor(.retraceMuted)

                    Picker("", selection: $selectedModelPickerTag) {
                        ForEach(OpenRouterConfig.popularModels, id: \.self) { modelName in
                            Text(modelName).tag(modelName)
                        }
                        Text("Custom Model...").tag("custom")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: selectedModelPickerTag) { newValue in
                        isCustomModel = (newValue == "custom")
                        if newValue != "custom" {
                            selectedModel = newValue
                        }
                    }

                    if isCustomModel || !OpenRouterConfig.popularModels.contains(selectedModel) {
                        HStack {
                            TextField("Enter any OpenRouter model slug (e.g. qwen/qwen-2.5-72b-instruct)", text: $customModelInput)
                                .textFieldStyle(.plain)
                                .font(.retraceMono)
                                .foregroundColor(.retraceInk)
                                .padding(10)
                                .background(Color.retraceSurface)
                                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous).stroke(Color.retraceBorderStrong, lineWidth: 1))

                            Button("Apply") {
                                let trimmed = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    selectedModel = trimmed
                                }
                            }
                            .buttonStyle(RetraceButtonStyle(.secondary))
                        }
                        .padding(.top, 4)
                    }
                }

                Divider().overlay(Color.retraceBorder)

                // Granular Context Window
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Context Window Size")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)
                        Spacer()
                        Text("\(Int(maxContextFrames)) frames")
                            .font(.retraceMonoSmall)
                            .monospacedDigit()
                            .foregroundColor(.retraceInk)
                    }

                    Slider(value: $maxContextFrames, in: 5...50, step: 5)
                        .tint(.retraceAccent)

                    Text("Number of highest-relevance OCR frames passed into the model prompt.")
                        .font(.retraceMeta)
                        .foregroundColor(.retraceMuted)
                }

                Divider().overlay(Color.retraceBorder)

                // Temperature Slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Temperature (Creativity vs Determinism)")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)
                        Spacer()
                        Text(String(format: "%.1f", temperature))
                            .font(.retraceMonoSmall)
                            .monospacedDigit()
                            .foregroundColor(.retraceInk)
                    }

                    Slider(value: $temperature, in: 0.0...1.0, step: 0.1)
                        .tint(.retraceAccent)

                    Text("Lower values (0.0 - 0.3) provide more factual, grounded citations.")
                        .font(.retraceMeta)
                        .foregroundColor(.retraceMuted)
                }
            }
            .retraceCard()

            // AI Visual Semantic Indexing
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable AI Visual Indexing")
                            .font(.retraceHeadline)
                            .foregroundColor(.retracePrimary)
                        Text("Processes frames in two stages: fast on-device Apple Intelligence baseline indexing (unlimited, zero network requests) followed by deep visual multi-layer cross-referencing (self-limited to 600 requests/day). Direct searches in the timeline have an independent dedicated quota of 100 requests/day. Screenshots from apps excluded from OCR are never sent.")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)
                    }

                    Spacer(minLength: 12)

                    Toggle("", isOn: $isSemanticIndexingEnabled)
                        .labelsHidden()
                        .toggleStyle(RetraceSwitchStyle())
                        .accessibilityLabel("Enable AI Visual Indexing")
                }

                if isSemanticIndexingEnabled {
                    Divider().overlay(Color.retraceBorder)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Indexing Model (must support image input)")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)

                        Picker("", selection: $indexingModelPickerTag) {
                            Text("NVIDIA Nemotron 3 Nano Omni (free, vision)").tag(OpenRouterCredentialsManager.defaultIndexingModel)
                            Text("Custom Model...").tag("custom")
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: indexingModelPickerTag) { newValue in
                            isCustomIndexingModel = (newValue == "custom")
                            if newValue != "custom" {
                                indexingModel = newValue
                            }
                        }

                        if isCustomIndexingModel || indexingModel != OpenRouterCredentialsManager.defaultIndexingModel {
                            HStack {
                                TextField("Enter a vision-capable OpenRouter model slug", text: $customIndexingModelInput)
                                    .textFieldStyle(.plain)
                                    .font(.retraceMono)
                                    .foregroundColor(.retraceInk)
                                    .padding(10)
                                    .background(Color.retraceSurface)
                                    .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous).stroke(Color.retraceBorderStrong, lineWidth: 1))

                                Button("Apply") {
                                    let trimmed = customIndexingModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        indexingModel = trimmed
                                    }
                                }
                                .buttonStyle(RetraceButtonStyle(.secondary))
                            }
                            .padding(.top, 4)
                        }
                    }

                    Divider().overlay(Color.retraceBorder)

                    HStack(spacing: 12) {
                        Button(action: {
                            isRestartingIndexing = true
                            restartStatusMessage = "Restarting and resetting backlog..."
                            NotificationCenter.default.post(name: .forceRestartSemanticIndexing, object: nil)
                            Task {
                                try? await Task.sleep(for: .seconds(1), clock: .continuous)
                                await MainActor.run {
                                    isRestartingIndexing = false
                                    restartStatusMessage = "AI indexing restarted & backlog reset"
                                }
                                try? await Task.sleep(for: .seconds(3), clock: .continuous)
                                await MainActor.run {
                                    if restartStatusMessage == "AI indexing restarted & backlog reset" {
                                        restartStatusMessage = nil
                                    }
                                }
                            }
                        }) {
                            HStack(spacing: 6) {
                                if isRestartingIndexing {
                                    ProgressView()
                                        .scaleEffect(0.6)
                                        .frame(width: 14, height: 14)
                                } else {
                                    RetraceSymbol("arrow.clockwise", size: 11, weight: .semibold, label: "")
                                }
                                Text(isRestartingIndexing ? "Restarting…" : "Force Restart Indexing")
                            }
                        }
                        .buttonStyle(RetraceButtonStyle(.secondary))
                        .disabled(isRestartingIndexing)
                        .help("Clears rate-limit backoff, resets stalled frames to pending, and immediately triggers an indexing cycle")

                        if let msg = restartStatusMessage {
                            Text(msg)
                                .font(.retraceMeta)
                                .foregroundColor(.retraceMuted)
                        }
                    }
                }
            }
            .retraceCard()
        }
        .onAppear {
            loadKeyStatus()
        }
    }

    private func loadKeyStatus() {
        hasStoredKey = OpenRouterCredentialsManager.hasAPIKey()
        // A persisted literal `"custom"` is the stale picker sentinel from before the Picker/
        // @AppStorage decoupling fix, not a real (if unrecognized) model slug — treating it as
        // one would populate the text field with the word "custom" and, if the user hits Apply
        // without editing it, re-persist the same broken value forever. Reset to a real default.
        if selectedModel == "custom" {
            selectedModel = "anthropic/claude-3.5-sonnet"
        }
        if OpenRouterConfig.popularModels.contains(selectedModel) {
            selectedModelPickerTag = selectedModel
        } else {
            isCustomModel = true
            customModelInput = selectedModel
            selectedModelPickerTag = "custom"
        }

        if indexingModel == OpenRouterCredentialsManager.defaultIndexingModel {
            indexingModelPickerTag = OpenRouterCredentialsManager.defaultIndexingModel
        } else {
            isCustomIndexingModel = true
            customIndexingModelInput = indexingModel
            indexingModelPickerTag = "custom"
        }
    }

    private func toggleKeyVisibility() {
        isShowingKey.toggle()
        if isShowingKey && apiKeyInput.isEmpty && hasStoredKey {
            if let stored = OpenRouterCredentialsManager.getAPIKey() {
                apiKeyInput = stored
            }
        }
    }

    private func copyKey() {
        let key = apiKeyInput.isEmpty ? (OpenRouterCredentialsManager.getAPIKey() ?? "") : apiKeyInput
        guard !key.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        testStatusMessage = "API Key copied to clipboard"
        testStatusIsError = false
    }

    private func saveKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try OpenRouterCredentialsManager.saveAPIKey(trimmed)
            hasStoredKey = true
            testStatusMessage = "API Key saved securely to Keychain ✓"
            testStatusIsError = false
        } catch {
            testStatusMessage = "Save failed: \(error.localizedDescription)"
            testStatusIsError = true
        }
    }

    private func deleteKey() {
        do {
            try OpenRouterCredentialsManager.deleteAPIKey()
            hasStoredKey = false
            apiKeyInput = ""
            testStatusMessage = "API Key removed from Keychain."
            testStatusIsError = false
        } catch {
            testStatusMessage = "Delete failed: \(error.localizedDescription)"
            testStatusIsError = true
        }
    }

    private func testConnection() {
        let trimmedInput = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedInput.isEmpty {
            saveKey()
        }

        let key = trimmedInput.isEmpty ? (OpenRouterCredentialsManager.getAPIKey() ?? "") : trimmedInput
        let model = (selectedModel == "custom" || isCustomModel) ? customModelInput.trimmingCharacters(in: .whitespacesAndNewlines) : selectedModel

        guard !key.isEmpty else {
            testStatusMessage = "Please enter an API Key first"
            testStatusIsError = true
            return
        }

        isTestingConnection = true
        testStatusMessage = nil

        Task {
            let client = OpenRouterClient()
            do {
                let success = try await client.testConnection(apiKey: key, model: model.isEmpty ? "anthropic/claude-3.5-sonnet" : model)
                await MainActor.run {
                    isTestingConnection = false
                    if success {
                        testStatusMessage = "Connection verified successfully ✓ (\(model))"
                        testStatusIsError = false
                    } else {
                        testStatusMessage = "Connection check failed."
                        testStatusIsError = true
                    }
                }
            } catch {
                await MainActor.run {
                    isTestingConnection = false
                    testStatusMessage = error.localizedDescription
                    testStatusIsError = true
                }
            }
        }
    }
}
