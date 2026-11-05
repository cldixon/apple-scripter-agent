import AppKit
import ServiceManagement
import Shared
import SwiftUI

/// Whether the things Automation Agent needs before automations can work are in place.
@MainActor
enum SetupChecklist {
    /// API key stored, runner registered and answering, and the runner trusted for Accessibility.
    static func requiredItemsDone(hasAPIKey: Bool, runner: RunnerController) -> Bool {
        hasAPIKey
            && runner.registration == .enabled
            && runner.isHealthy
            && runner.accessibilityTrusted == true
    }
}

extension RunnerController {
    /// Accessibility as of the last successful ping, or nil when the runner has not answered.
    var accessibilityTrusted: Bool? {
        if case .succeeded(let result) = pingState {
            return result.response.accessibilityTrusted
        }
        return nil
    }
}

/// How one checklist item stands.
enum SetupItemState {
    case done
    case needsAction
    case unknown
    case optional

    var symbol: String {
        switch self {
        case .done: "checkmark.circle.fill"
        case .needsAction: "exclamationmark.circle.fill"
        case .unknown: "questionmark.circle"
        case .optional: "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .done: .green
        case .needsAction: .orange
        case .unknown, .optional: .secondary
        }
    }
}

/// One row: status icon, what it is, where it stands, and a button to fix it.
struct SetupRow<Actions: View>: View {
    let title: String
    let detail: String
    let state: SetupItemState
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: state.symbol)
                .foregroundStyle(state.color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .bold()
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actions()
        }
        .padding(.vertical, 2)
    }
}

/// The reference library as the runner reports it.
enum ReferenceLibraryState: Equatable {
    case unchecked
    case checking
    case ready
    case empty
    case failed(String)
}

/// First-run checklist: every requirement with its live status and a way to fix it.
struct SetupView: View {
    @Environment(APIKeyController.self) private var apiKey
    @Environment(RunnerController.self) private var runner
    @Environment(AppNavigator.self) private var navigator
    @State private var reference = ReferenceLibraryState.unchecked

    var body: some View {
        Form {
            Section {
                Text(
                    "Automation Agent needs these before automations can run. "
                        + "Fix each orange item, then choose Check Again."
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            Section("Required") {
                apiKeyRow
                registrationRow
                connectionRow
                accessibilityRow
            }
            Section("Also good to know") {
                notificationsRow
                referenceRow
            }
            Section {
                HStack {
                    Button("Check Again") {
                        Task { await checkAll() }
                    }
                    .disabled(runner.isPinging)
                    if runner.isPinging {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                    if SetupChecklist.requiredItemsDone(hasAPIKey: apiKey.hasKey, runner: runner) {
                        Label("Everything required is done.", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Setup")
        .task { await checkReference() }
    }

    private func checkAll() async {
        runner.refreshStatus()
        await runner.ping()
        await checkReference()
    }

    /// The reference library is ready when a search for a common word finds something.
    private func checkReference() async {
        reference = .checking
        do {
            let reply = try await RunnerClient().send(.searchReference(query: "AppleScript", limit: 1), timeout: 10)
            switch reply {
            case .referenceHits(let hits):
                reference = hits.isEmpty ? .empty : .ready
            case .failure(let text):
                reference = .failed(text)
            default:
                reference = .failed("The runner sent an unexpected reply.")
            }
        } catch {
            reference = .failed(error.localizedDescription)
        }
    }
}

// MARK: Rows

extension SetupView {
    private var apiKeyRow: some View {
        SetupRow(
            title: "Anthropic API key",
            detail: apiKey.hasKey
                ? "Stored in your login Keychain. Chat uses it to talk to Claude."
                : "Not set. Chat needs your own Anthropic API key.",
            state: apiKey.hasKey ? .done : .needsAction
        ) {
            Button(apiKey.hasKey ? "Change…" : "Add Key…") {
                navigator.selection = .settings
            }
        }
    }

    private var registrationRow: some View {
        SetupRow(
            title: "Background runner registered",
            detail: "\(runner.registration.label). \(runner.registration.explanation)",
            state: runner.registration == .enabled ? .done : .needsAction
        ) {
            switch runner.registration {
            case .enabled:
                EmptyView()
            case .requiresApproval:
                Button("Open Login Items…") { runner.openLoginItemsSettings() }
            default:
                Button("Register") {
                    runner.register()
                    Task { await runner.ping() }
                }
            }
        }
    }

    private var connectionRow: some View {
        SetupRow(title: "Runner answers", detail: connectionDetail, state: connectionState) {
            Button("Ping") {
                Task { await runner.ping() }
            }
            .disabled(runner.isPinging)
        }
    }

    private var connectionState: SetupItemState {
        switch runner.pingState {
        case .succeeded: .done
        case .failed: .needsAction
        case .idle, .pinging: .unknown
        }
    }

    private var connectionDetail: String {
        switch runner.pingState {
        case .idle: "Not checked yet."
        case .pinging: "Waiting for the runner…"
        case .succeeded(let result): "Runner \(result.response.runnerVersion) answered."
        case .failed(let message): message
        }
    }

    private var accessibilityRow: some View {
        SetupRow(
            title: "Accessibility for the runner",
            detail: accessibilityDetail,
            state: accessibilityState
        ) {
            if runner.accessibilityTrusted == false {
                Button("Allow…") {
                    Task { await runner.requestAccessibility() }
                }
            }
        }
    }

    private var accessibilityState: SetupItemState {
        switch runner.accessibilityTrusted {
        case .some(true): .done
        case .some(false): .needsAction
        case .none: .unknown
        }
    }

    private var accessibilityDetail: String {
        switch runner.accessibilityTrusted {
        case .some(true):
            "Allowed. Automations can type, paste and press keys."
        case .some(false):
            "Not allowed. Turn on Automation Agent Runner in System Settings > Privacy & Security > "
                + "Accessibility, then choose Check Again."
        case .none:
            "Checked once the runner answers."
        }
    }

    private var notificationsRow: some View {
        SetupRow(
            title: "Notifications for the runner",
            detail: "macOS asks the first time the runner sends one (a notify step, or an automation "
                + "becoming broken). Change it later in System Settings > Notifications.",
            state: .optional
        ) {
            Button("Open Notifications Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private var referenceRow: some View {
        SetupRow(title: "Reference library", detail: referenceDetail, state: referenceState) {
            Button("Check") {
                Task { await checkReference() }
            }
            .disabled(reference == .checking)
        }
    }

    private var referenceState: SetupItemState {
        switch reference {
        case .ready: .done
        case .empty, .failed: .needsAction
        case .unchecked, .checking: .unknown
        }
    }

    private var referenceDetail: String {
        switch reference {
        case .unchecked: "Not checked yet."
        case .checking: "Searching the runner's reference notes…"
        case .ready: "The agent's reference notes are indexed and searchable."
        case .empty: "The reference library is empty. Reinstall the app to restore its notes."
        case .failed(let message): "Could not search the reference library: \(message)"
        }
    }
}
