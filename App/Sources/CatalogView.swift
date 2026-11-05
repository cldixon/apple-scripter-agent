import Shared
import SwiftUI

/// Installed automations: a searchable list on the left, the selected one on the right,
/// with its versions (from the catalog's git history), tests and recent runs.
struct CatalogView: View {
    @Environment(CatalogController.self) private var catalog

    var body: some View {
        @Bindable var catalog = catalog
        VStack(alignment: .leading, spacing: 0) {
            if let message = catalog.message {
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary)
            }
            HSplitView {
                AutomationList()
                    .frame(minWidth: 220, idealWidth: 260)
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
        .sheet(item: $catalog.diffSheet) { sheet in
            DiffSheetView(sheet: sheet)
        }
        .task { await catalog.refresh() }
    }
}

/// Search field and status filter above the list of automations.
private struct AutomationList: View {
    @Environment(CatalogController.self) private var catalog

    var body: some View {
        @Bindable var catalog = catalog
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                TextField("Search", text: $catalog.searchText)
                    .textFieldStyle(.roundedBorder)
                Picker("Status", selection: $catalog.statusFilter) {
                    Text("All").tag(AutomationStatus?.none)
                    ForEach(AutomationStatus.allCases) { status in
                        Text(status.displayName).tag(AutomationStatus?.some(status))
                    }
                }
            }
            .padding(8)
            List(catalog.filteredAutomations, selection: $catalog.selection) { automation in
                AutomationRow(automation: automation)
            }
            .overlay {
                if catalog.automations.isEmpty {
                    ContentUnavailableView(
                        "No automations",
                        systemImage: "tray",
                        description: Text("Install the date example or a manifest.json from the toolbar.")
                    )
                } else if catalog.filteredAutomations.isEmpty {
                    ContentUnavailableView.search(text: catalog.searchText)
                }
            }
        }
    }
}

private struct AutomationRow: View {
    let automation: AutomationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(automation.name)
            }
            Text("\(automation.trigger) · \(automation.status.displayName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .tag(automation.id)
    }

    private var statusColor: Color {
        switch automation.status {
        case .active: .green
        case .disabled: .gray
        case .broken: .red
        case .draft, .validating, .awaitingApproval: .orange
        }
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
                Toggle("Enabled", isOn: Binding(
                    get: { automation.isEnabled },
                    set: { enabled in Task { await catalog.setEnabled(automation.id, enabled: enabled) } }
                ))
                .disabled(catalog.busyWith != nil)
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
                ValidationSection(issues: automation.issues)
            }
            MonitoringSection(automation: automation)
            VersionsSection(automation: automation)
            TestsSection(automation: automation)
            RecentRunsSection(runs: catalog.runs(for: automation.id))
        }
        .formStyle(.grouped)
        .task(id: automation.id) { await catalog.loadHistory(automation.id) }
    }

    private var statusText: String {
        if automation.status == .broken, let error = automation.registrationError {
            return "Broken: \(error)"
        }
        return automation.status.displayName
    }
}

private struct ValidationSection: View {
    let issues: [ValidationIssue]

    var body: some View {
        Section("Validation") {
            ForEach(issues, id: \.self) { issue in
                Label(
                    "\(issue.location): \(issue.message)",
                    systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle"
                )
                .foregroundStyle(issue.severity == .error ? .red : .primary)
            }
        }
    }
}

/// Committed versions, newest first, with diff and restore.
private struct VersionsSection: View {
    @Environment(CatalogController.self) private var catalog
    let automation: AutomationSummary

    var body: some View {
        Section("Versions") {
            let versions = catalog.versions[automation.id] ?? []
            if let problem = catalog.historyProblem {
                Text(problem).foregroundStyle(.secondary)
            } else if versions.isEmpty {
                Text("No version history yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(versions.enumerated()), id: \.element.id) { position, version in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(version.version.map { "v\($0)" } ?? "—").bold()
                        Text(version.message)
                        Spacer()
                        Text(version.shortHash).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(version.date.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Show diff") { Task { await catalog.showDiff(automation.id, version: version) } }
                        if position > 0 {
                            Button("Diff to latest") {
                                Task { await catalog.showDiffToLatest(automation.id, version: version) }
                            }
                            if version.version != nil {
                                Button("Restore this version") {
                                    Task { await catalog.restore(automation.id, version: version) }
                                }
                            }
                        }
                    }
                    .controlSize(.small)
                    .disabled(catalog.busyWith != nil)
                }
            }
        }
    }
}

private struct TestsSection: View {
    @Environment(CatalogController.self) private var catalog
    let automation: AutomationSummary

    var body: some View {
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
    }
}

private struct RecentRunsSection: View {
    let runs: [RunRecord]

    var body: some View {
        Section("Recent runs") {
            if runs.isEmpty {
                Text("No runs yet.").foregroundStyle(.secondary)
            } else {
                ForEach(runs.prefix(10)) { run in
                    RunRow(run: run)
                }
            }
        }
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

/// A diff as monospaced, selectable text.
private struct DiffSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let sheet: DiffSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sheet.title).font(.headline)
            ScrollView([.vertical, .horizontal]) {
                Text(sheet.text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(.quaternary)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 420)
    }
}
