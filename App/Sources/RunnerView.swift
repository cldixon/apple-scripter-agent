import ServiceManagement
import SwiftUI

/// M0's working screen: is the runner registered, does it answer, and what has happened.
struct RunnerView: View {
    @Environment(RunnerController.self) private var runner

    var body: some View {
        Form {
            registrationSection
            connectionSection
            SnippetView()
            activitySection
        }
        .formStyle(.grouped)
        .navigationTitle("Runner")
    }

    private var registrationSection: some View {
        Section("Background runner") {
            LabeledContent("Launch agent", value: runner.registration.label)
            Text(runner.registration.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Register") { runner.register() }
                    .disabled(runner.registration == .enabled)
                Button("Unregister") { runner.unregister() }
                    .disabled(runner.registration == .notRegistered)
                Button("Open Login Items Settings") { runner.openLoginItemsSettings() }
                Spacer()
                Button("Refresh") { runner.refreshStatus() }
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            HStack {
                Button("Ping Runner") {
                    Task { await runner.ping() }
                }
                .disabled(runner.isPinging)
                if runner.isPinging {
                    ProgressView().controlSize(.small)
                }
            }
            switch runner.pingState {
            case .idle:
                Text("Not pinged yet.").foregroundStyle(.secondary)
            case .pinging:
                Text("Waiting for the runner…").foregroundStyle(.secondary)
            case .succeeded(let result):
                LabeledContent("Round trip", value: result.roundTrip.millisecondsText)
                LabeledContent("Runner version", value: result.response.runnerVersion)
                LabeledContent("Process ID", value: String(result.response.processID))
                LabeledContent(
                    "Running since",
                    value: result.response.startedAt.formatted(date: .abbreviated, time: .standard)
                )
                LabeledContent("Pings served", value: String(result.response.pingsServed))
                LabeledContent("Accessibility") {
                    if result.response.accessibilityTrusted {
                        Text("Allowed")
                    } else {
                        HStack {
                            Text("Not allowed: automations cannot type or paste").foregroundStyle(.red)
                            Button("Allow…") {
                                Task {
                                    await runner.requestAccessibility()
                                }
                            }
                        }
                    }
                }
                LabeledContent("Location", value: result.response.bundlePath)
            case .failed(let message):
                Text(message).foregroundStyle(.red)
            }
        }
    }

    private var activitySection: some View {
        Section("Activity") {
            if runner.log.isEmpty {
                Text("No activity yet.").foregroundStyle(.secondary)
            } else {
                ForEach(runner.log.reversed()) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.date.formatted(date: .omitted, time: .standard))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(entry.message)
                    }
                }
            }
        }
    }
}
