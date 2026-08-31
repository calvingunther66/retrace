import SwiftUI
import Shared
import Search

public struct OpenRouterSettingsView: View {
    @AppStorage("openRouterEnabled", store: settingsStore) private var isEnabled: Bool = false
    @AppStorage(OpenRouterCredentialsManager.selectedModelDefaultsKey, store: settingsStore) private var selectedModel: String = "anthropic/claude-3.5-sonnet"
    @AppStorage(OpenRouterCredentialsManager.maxContextFramesDefaultsKey, store: settingsStore) private var maxContextFrames: Double = 25
    @AppStorage("openRouterTemperature", store: settingsStore) private var temperature: Double = 0.2

    @AppStorage(OpenRouterCredentialsManager.semanticIndexingEnabledDefaultsKey, store: settingsStore) private var isSemanticIndexingEnabled: Bool = false
    @AppStorage(OpenRouterCredentialsManager.webSSHIntegrationEnabledDefaultsKey, store: settingsStore) private var isWebSSHIntegrationEnabled: Bool = false
    @AppStorage(OpenRouterCredentialsManager.indexingModelDefaultsKey, store: settingsStore) private var indexingModel: String = OpenRouterCredentialsManager.defaultIndexingModel
    @State private var customIndexingModelInput: String = ""
    @State private var isCustomIndexingModel: Bool = false

    @State private var apiKeyInput: String = ""
    @State private var hasStoredKey: Bool = false
    @State private var isShowingKey: Bool = false
    @State private var isTestingConnection: Bool = false
    @State private var testStatusMessage: String? = nil
    @State private var testStatusIsError: Bool = false
    @State private var customModelInput: String = ""
    @State private var isCustomModel: Bool = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Header Card
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient.retraceAccentGradient.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(LinearGradient.retraceAccentGradient)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenRouter & AI Search")
                            .font(.retraceTitle3)
                            .foregroundColor(.retracePrimary)
                        Text("Granular AI search, natural language queries, and timeline Q&A with any LLM")
                            .font(.retraceCaption)
                            .foregroundColor(.retraceSecondary)
                    }
                }
            }
            .padding(.bottom, 4)

            // Master Enable Toggle
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable AI Granular Search")
                            .font(.retraceBodyMedium)
                            .foregroundColor(.retracePrimary)
                        Text("Synthesize answers across screen history using OpenRouter models")
                            .font(.retraceCaption)
                            .foregroundColor(.retraceSecondary)
                    }
                }
                .toggleStyle(SwitchToggleStyle(tint: .retraceAccent))
            }
            .padding(16)
            .background(Color.white.opacity(0.04))
            .cornerRadius(12)

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
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.retraceAccent)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("OpenRouter API Key")
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)

                    HStack(spacing: 8) {
                        if isShowingKey {
                            TextField("sk-or-v1-...", text: $apiKeyInput)
                                .textFieldStyle(.plain)
                                .font(.system(.body, design: .monospaced))
                                .padding(10)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(8)
                                .onSubmit {
                                    saveKey()
                                }
                        } else {
                            SecureField(hasStoredKey ? "••••••••••••••••••••••••••••••••" : "sk-or-v1-...", text: $apiKeyInput)
                                .textFieldStyle(.plain)
                                .font(.system(.body, design: .monospaced))
                                .padding(10)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(8)
                                .onSubmit {
                                    saveKey()
                                }
                        }

                        Button(action: toggleKeyVisibility) {
                            Image(systemName: isShowingKey ? "eye.slash" : "eye")
                                .foregroundColor(.retraceSecondary)
                                .frame(width: 36, height: 36)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .help(isShowingKey ? "Hide API key" : "Show API key")

                        if hasStoredKey || !apiKeyInput.isEmpty {
                            Button(action: copyKey) {
                                Image(systemName: "doc.on.doc")
                                    .foregroundColor(.retraceSecondary)
                                    .frame(width: 36, height: 36)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .help("Copy API key to clipboard")
                        }

                        Button(action: saveKey) {
                            Text("Save")
                                .font(.retraceCaptionMedium)
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(Color.retraceAccent)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if hasStoredKey {
                            Button(action: deleteKey) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red.opacity(0.8))
                                    .frame(width: 36, height: 36)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .help("Delete API key from Keychain")
                        }
                    }

                    if hasStoredKey {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.shield.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                            Text("API Key is securely saved in macOS Keychain")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceSecondary)
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
                                Image(systemName: "bolt.horizontal.fill")
                                    .font(.system(size: 11))
                            }
                            Text("Test API Connection")
                                .font(.retraceCaptionMedium)
                        }
                        .foregroundColor(.retracePrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .disabled(isTestingConnection || (!hasStoredKey && apiKeyInput.isEmpty))

                    if let message = testStatusMessage {
                        HStack(spacing: 6) {
                            Image(systemName: testStatusIsError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                .foregroundColor(testStatusIsError ? .orange : .green)
                            Text(message)
                                .font(.retraceCaption)
                                .foregroundColor(.retracePrimary)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.04))
            .cornerRadius(12)

            // Model Selection
            VStack(alignment: .leading, spacing: 16) {
                Text("Model Selection")
                    .font(.retraceHeadline)
                    .foregroundColor(.retracePrimary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Selected Model")
                        .font(.retraceCaptionMedium)
                        .foregroundColor(.retraceSecondary)

                    Picker("", selection: $selectedModel) {
                        ForEach(OpenRouterConfig.popularModels, id: \.self) { modelName in
                            Text(modelName).tag(modelName)
                        }
                        Text("Custom Model...").tag("custom")
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: selectedModel) { newValue in
                        isCustomModel = (newValue == "custom")
                    }

                    if isCustomModel || !OpenRouterConfig.popularModels.contains(selectedModel) {
                        HStack {
                            TextField("Enter any OpenRouter model slug (e.g. qwen/qwen-2.5-72b-instruct)", text: $customModelInput)
                                .textFieldStyle(.plain)
                                .font(.system(.body, design: .monospaced))
                                .padding(10)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(8)

                            Button("Apply") {
                                let trimmed = customModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    selectedModel = trimmed
                                }
                            }
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.retracePrimary)
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(8)
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 4)
                    }
                }

                Divider().opacity(0.1)

                // Granular Context Window
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Context Window Size")
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.retraceSecondary)
                        Spacer()
                        Text("\(Int(maxContextFrames)) frames")
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.retracePrimary)
                    }

                    Slider(value: $maxContextFrames, in: 5...50, step: 5)
                        .tint(.retraceAccent)

                    Text("Number of highest-relevance OCR frames passed into the model prompt.")
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary.opacity(0.8))
                }

                Divider().opacity(0.1)

                // Temperature Slider
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Temperature (Creativity vs Determinism)")
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.retraceSecondary)
                        Spacer()
                        Text(String(format: "%.1f", temperature))
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.retracePrimary)
                    }

                    Slider(value: $temperature, in: 0.0...1.0, step: 0.1)
                        .tint(.retraceAccent)

                    Text("Lower values (0.0 - 0.3) provide more factual, grounded citations.")
                        .font(.retraceCaption2)
                        .foregroundColor(.retraceSecondary.opacity(0.8))
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.04))
            .cornerRadius(12)

            // AI Visual Semantic Indexing
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $isSemanticIndexingEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable AI Visual Indexing")
                            .font(.retraceHeadline)
                            .foregroundColor(.retracePrimary)
                        Text("Sends downscaled screenshots to an AI vision model via OpenRouter so search can match on visual content like icons, diagrams, and images — not just OCR text. Runs slowly in the background (self-limited to ~600 backfill requests/day). Screenshots from apps excluded from OCR are never sent.")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.8))
                    }
                }
                .toggleStyle(.switch)

                if isSemanticIndexingEnabled {
                    Divider().opacity(0.1)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Indexing Model (must support image input)")
                            .font(.retraceCaptionMedium)
                            .foregroundColor(.retraceSecondary)

                        Picker("", selection: $indexingModel) {
                            Text("NVIDIA Nemotron 3 Nano Omni (free, vision)").tag(OpenRouterCredentialsManager.defaultIndexingModel)
                            Text("Custom Model...").tag("custom")
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onChange(of: indexingModel) { newValue in
                            isCustomIndexingModel = (newValue == "custom")
                        }

                        if isCustomIndexingModel || indexingModel != OpenRouterCredentialsManager.defaultIndexingModel {
                            HStack {
                                TextField("Enter a vision-capable OpenRouter model slug", text: $customIndexingModelInput)
                                    .textFieldStyle(.plain)
                                    .font(.system(.body, design: .monospaced))
                                    .padding(10)
                                    .background(Color.white.opacity(0.06))
                                    .cornerRadius(8)

                                Button("Apply") {
                                    let trimmed = customIndexingModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if !trimmed.isEmpty {
                                        indexingModel = trimmed
                                    }
                                }
                                .font(.retraceCaptionMedium)
                                .foregroundColor(.retracePrimary)
                                .padding(.horizontal, 12)
                                .frame(height: 36)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(8)
                                .buttonStyle(.plain)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }
            .padding(16)
            .background(Color.white.opacity(0.04))
            .cornerRadius(12)

            // WebSSH Terminal Integration
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $isWebSSHIntegrationEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.orange)
                            Text("Enable WebSSH Terminal Integration")
                                .font(.retraceHeadline)
                                .foregroundColor(.retracePrimary)
                        }
                        Text("Lets AI search read your WebSSH terminal sessions and, with your explicit approval on every single command, run commands in them. A confirmation dialog always appears before any command executes — text you merely viewed on screen can never run a command on its own. Off by default; only enable this if you understand the risk.")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceSecondary.opacity(0.8))
                    }
                }
                .toggleStyle(.switch)
            }
            .padding(16)
            .background(Color.white.opacity(0.04))
            .cornerRadius(12)
        }
        .onAppear {
            loadKeyStatus()
            isCustomIndexingModel = (indexingModel != OpenRouterCredentialsManager.defaultIndexingModel)
            if isCustomIndexingModel {
                customIndexingModelInput = indexingModel
            }
        }
    }

    private func loadKeyStatus() {
        hasStoredKey = OpenRouterCredentialsManager.hasAPIKey()
        if !OpenRouterConfig.popularModels.contains(selectedModel) {
            isCustomModel = true
            customModelInput = selectedModel
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
