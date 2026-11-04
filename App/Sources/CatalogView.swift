import Shared
import SwiftUI

/// Installed automations: a list on the left, the selected one on the right.
/// Early version (M1): install from a file, run, test, remove. M3 adds versions and search.
struct CatalogView: View {
    @Environment(CatalogController.self) private var catalog

    var body: some View {
        @Bindable var catalog = catalog
        VStack(alignment: .leading, spacing: 0) {
            if let message = catalog.message {
                Text(message)
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
            }
            HSplitView {
                List(catalog.automations, selection: $catalog.selection) { automation in
                    AutomationRow(automation: automation)
                }
                .frame(minWidth: 220, idealWidth: 260)
                .overlay {
                    if catalog.automations.isEmpty {
                        ContentUnavailableView(
                            "No automations",
                            systemImage: "tray",
                            description: Text("Install the date example or a manifest.json from the toolbar.")
                        )
                    }
                }
                Group {
                    if let automation = catalog.selected {
                        AutomationDetail(automation: automation)
                    } else {
                        Text("Select an automation").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Catalog")
        .toolbar {
            ToolbarItemGroup {
                Toggle("Pause All", isOn: Binding(
                    get: { catalog.isPaused },
                    set: { paused in Task { await catalog.setPaused(paused) } }
                ))
                Button("Install Date Example") { Task { await catalog.installDateExample() } }
                Button("Install Manifest…") { Task { await catalog.installFromFile() } }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await catalog.refresh() } }
            }
        }
        .task { await catalog.refresh() }
    }
}

private struct AutomationRow: View {
    let automation: AutomationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(automation.isActive ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(automation.name)
            }
            Text(automation.trigger)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .tag(automation.id)
    }
}

private struct AutomationDetail: View {
    @Environment(CatalogController.self) private var catalog
    let automation: AutomationSummary

    var body: some View {
        Form {
            Section {
                LabeledContent("Trigger", value: automation.trigger)
                LabeledContent("Status", value: statusText)
                LabeledContent("Steps", value: automation.stepTypes.joined(separator: " → "))
                LabeledContent(
                    "Permissions",
                    value: automation.permissions.isEmpty
                        ? "None"
                        : automation.permissions.map(\.rawValue).joined(separator: ", ")
                )
                LabeledContent("Version", value: String(automation.version))
                if automation.destructive {
                    Text("Destructive: changes or deletes data").foregroundStyle(.red)
                }
                if let description = automation.description {
                    Text(description).foregroundStyle(.secondary)
                }
            } header: {
                Text(automation.name).font(.title3).bold()
            }

            Section {
                HStack {
                    Button("Run Now") { Task { await catalog.run(automation.id) } }
                    Button("Run Tests") { Task { await catalog.test(automation.id) } }
                    Spacer()
                    Button("Show in Finder") { catalog.revealInFinder(automation) }
                    Button("Remove", role: .destructive) { Task { await catalog.remove(automation.id) } }
                }
                .disabled(catalog.busyWith != nil)
                if catalog.busyWith == automation.id {
                    ProgressView().controlSize(.small)
                }
            }

            if !automation.issues.isEmpty {
                Section("Validation") {
                    ForEach(automation.issues, id: \.self) { issue in
                        Label(
                            "\(issue.location): \(issue.message)",
                            systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle"
                        )
                        .foregroundStyle(issue.severity == .error ? .red : .primary)
                    }
                }
            }

            Section("Tests (\(automation.testCount) declared)") {
                if let report = catalog.testReports[automation.id] {
                    Text("Ran \(report.ranAt.formatted(date: .omitted, time: .standard))")
                        .foregroundStyle(.secondary)
                    ForEach(report.results) { result in
                        Label(
                            "\(result.name): \(result.message)",
                            systemImage: result.passed ? "checkmark.circle" : "xmark.circle"
                        )
                        .foregroundStyle(result.passed ? Color.primary : Color.red)
                    }
                } else {
                    Text("Not run yet. Harness tests open a small window and type into it.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Recent runs") {
                let runs = catalog.runs(for: automation.id)
                if runs.isEmpty {
                    Text("No runs yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(runs.prefix(10)) { run in
                        RunRow(run: run)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        if let error = automation.registrationError { return "Not active: \(error)" }
        return automation.isActive ? "Active" : "Not active"
    }
}

private struct RunRow: View {
    let run: RunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: run.outcome == .succeeded ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(run.outcome == .succeeded ? Color.green : Color.red)
                Text(run.startedAt.formatted(date: .abbreviated, time: .standard))
                Text(run.cause.rawValue).foregroundStyle(.secondary)
                Spacer()
                Text("\(run.duration.formatted(.number.precision(.fractionLength(2)))) s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let error = run.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}
