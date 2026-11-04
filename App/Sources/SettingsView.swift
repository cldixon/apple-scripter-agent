import AgentCore
import SwiftUI

/// API key, model, effort and spend settings.
struct SettingsView: View {
    @Environment(AgentSettings.self) private var settings
    @Environment(APIKeyController.self) private var apiKey
    @Environment(ChatController.self) private var chat
    @State private var replacementKey = ""
    @State private var isConfirmingRemoval = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            apiKeySection
            ModelSettingsSection(settings: settings)
            Section("Limits") {
                TextField(
                    "Spend cap per conversation",
                    value: $settings.spendCapUSD,
                    format: .currency(code: "USD")
                )
                Stepper(
                    "Tool rounds per message: \(settings.maxToolRounds)",
                    value: $settings.maxToolRounds,
                    in: 1...200
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .confirmationDialog("Remove the API key?", isPresented: $isConfirmingRemoval) {
            Button("Remove Key", role: .destructive) {
                chat.stop()
                apiKey.remove()
            }
        } message: {
            Text("The key is deleted from the Keychain and the app returns to setup.")
        }
    }

    private var apiKeySection: some View {
        Section("Anthropic API key") {
            LabeledContent("Status", value: apiKey.hasKey ? "Stored in the Keychain" : "Not set")
            SecureField("Paste a new key to replace it", text: $replacementKey)
            HStack {
                Button("Validate and Replace") {
                    Task {
                        if await apiKey.validateAndSave(replacementKey) {
                            replacementKey = ""
                        }
                    }
                }
                .disabled(replacementKey.isEmpty || apiKey.isValidating)
                if apiKey.isValidating {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("Remove Key…", role: .destructive) {
                    isConfirmingRemoval = true
                }
                .disabled(!apiKey.hasKey)
            }
            if let message = apiKey.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
            }
        }
    }
}

struct ModelSettingsSection: View {
    @Bindable var settings: AgentSettings

    var body: some View {
        Section("Model") {
            Picker("Model", selection: $settings.model) {
                ForEach(ClaudeModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            Picker("Effort", selection: $settings.effort) {
                ForEach(Effort.allCases) { effort in
                    Text(effort.displayName).tag(effort)
                }
            }
            Toggle("Retry declined requests on a fallback model", isOn: $settings.serverSideFallback)
            Text("Changes apply to the next message. Higher effort thinks longer and costs more.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Shown instead of the main window until an API key is stored.
struct OnboardingView: View {
    @Environment(APIKeyController.self) private var apiKey
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect to Claude")
                .font(.largeTitle)
                .bold()
            Text(
                "Automation Agent talks to Claude with your own Anthropic API key. "
                    + "The key is checked once, then kept in your login Keychain. "
                    + "Usage is billed to your Anthropic account."
            )
            .fixedSize(horizontal: false, vertical: true)
            SecureField("Anthropic API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Button("Validate and Continue", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.isEmpty || apiKey.isValidating)
                if apiKey.isValidating {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let message = apiKey.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
            }
            if let consoleURL = URL(string: "https://platform.claude.com/settings/keys") {
                Link("Create a key in the Claude Console", destination: consoleURL)
            }
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: 560, maxHeight: .infinity, alignment: .topLeading)
    }

    private func save() {
        Task {
            if await apiKey.validateAndSave(key) {
                key = ""
            }
        }
    }
}
