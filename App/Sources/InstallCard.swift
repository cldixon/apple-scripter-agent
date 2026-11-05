import Shared
import SwiftUI

/// The approval card for `request_install`: everything that will be installed, the last
/// validation report, and Approve (enabled only after a passing validation; a destructive
/// automation needs a second confirmation) or Decline. When only harness tests failed, Install
/// Anyway is offered behind a warning.
struct InstallCard: View {
    let approval: InstallApproval
    let cardID: UUID
    let pending: Bool
    let center: InteractionCenter
    @State private var confirmingDestructive = false
    @State private var confirmingInstallAnyway = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Install \"\(approval.name)\"?").font(.headline)
            Text(approval.summary).textSelection(.enabled)
            InstallDetails(approval: approval)
            ValidationReportView(report: approval.report)
            if pending {
                buttons
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        if confirmingDestructive {
            Text("This automation is destructive: it can delete, move or overwrite your data, or send messages.")
                .foregroundStyle(.red)
            HStack {
                Button("Yes, Install It") { center.approve(cardID, label: "Approved (destructive, confirmed)") }
                Button("Cancel") { confirmingDestructive = false }
            }
        } else if confirmingInstallAnyway {
            Text(
                "A harness test failed, so typing or pasting into a window has not been checked. "
                    + "Install only if you will try it yourself right away."
            )
                .foregroundStyle(.orange)
            HStack {
                Button("Yes, Install Anyway") {
                    center.approve(cardID, label: "Approved despite a failing harness test")
                }
                Button("Cancel") { confirmingInstallAnyway = false }
            }
        } else if approval.canInstallAnyway {
            HStack {
                Button("Install Anyway…") { confirmingInstallAnyway = true }
                Text("Only the harness test failed.").font(.caption).foregroundStyle(.secondary)
            }
        } else {
            HStack {
                Button("Approve and Install") {
                    if approval.destructive {
                        confirmingDestructive = true
                    } else {
                        center.approve(cardID)
                    }
                }
                .disabled(!approval.canApprove)
                if !approval.canApprove {
                    Text("Approve needs a passing validation.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        DeclineRow(center: center, cardID: cardID)
    }
}

/// Id, trigger, steps with every script in full, other files, permissions and the destructive flag.
struct InstallDetails: View {
    let approval: InstallApproval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Id", value: approval.draftID)
            LabeledContent("Trigger", value: approval.trigger)
            LabeledContent(
                "Permissions",
                value: approval.permissions.isEmpty ? "none" : approval.permissions.joined(separator: ", ")
            )
            if approval.destructive {
                Label(
                    "Destructive: deletes, moves or overwrites data, or sends messages",
                    systemImage: "exclamationmark.triangle"
                )
                    .foregroundStyle(.red)
                    .bold()
            }
            if let problem = approval.parseProblem {
                Text(problem).foregroundStyle(.red)
                Text("manifest.json").font(.caption).bold()
                ScriptBlock(text: approval.rawManifest)
            }
            ForEach(approval.steps) { step in
                StepPreviewView(step: step)
            }
            ForEach(approval.otherFiles, id: \.path) { file in
                Text(file.path).font(.caption).bold()
                ScriptBlock(text: file.contents)
            }
        }
    }
}

struct StepPreviewView: View {
    let step: StepPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Step \(step.id + 1): \(step.type)").bold()
            ForEach(step.details, id: \.self) { detail in
                Text(detail).font(.callout).textSelection(.enabled)
            }
            if let label = step.scriptLabel {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            if let script = step.script {
                ScriptBlock(text: script)
            }
        }
    }
}

struct ValidationReportView: View {
    let report: TestReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let report {
                Text("Validation: \(report.passed ? "passed" : "failed")")
                    .bold()
                    .foregroundStyle(report.passed ? Color.green : Color.red)
                ForEach(report.issues, id: \.self) { issue in
                    Text(issue.description)
                        .font(.callout)
                        .foregroundStyle(issue.severity == .error ? Color.red : Color.orange)
                }
                ForEach(report.results) { result in
                    Text("\(result.passed ? "PASS" : "FAIL") \(result.name): \(result.message)")
                        .font(.callout)
                        .foregroundStyle(result.passed ? Color.primary : Color.red)
                }
            } else {
                Text("Not validated").bold().foregroundStyle(.orange)
            }
        }
        .textSelection(.enabled)
    }
}
