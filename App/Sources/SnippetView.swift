import Shared
import SwiftUI

/// Debug form for `run_snippet`: run a short script in the runner and see what it returns.
/// In M5 the agent sends snippets itself, after asking you.
struct SnippetView: View {
    @State private var language: ScriptLanguage = .applescript
    @State private var source = "tell application \"Finder\" to get name of every disk"
    @State private var timeout = 10.0
    @State private var result: ScriptResult?
    @State private var failure: String?
    @State private var note: String?
    @State private var isRunning = false

    private let client = RunnerClient()

    var body: some View {
        Section("Run snippet (debug)") {
            Picker("Language", selection: $language) {
                Text("AppleScript").tag(ScriptLanguage.applescript)
                Text("JavaScript (JXA)").tag(ScriptLanguage.jxa)
                Text("Shell (zsh)").tag(ScriptLanguage.shell)
            }
            TextEditor(text: $source)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 80)
            Stepper("Timeout: \(Int(timeout)) s", value: $timeout, in: 1...120)
            HStack {
                Button("Compile") { Task { await send(.compile(language: language, source: source)) } }
                Button("Run Snippet") {
                    Task { await send(.runSnippet(language: language, source: source, timeout: timeout)) }
                }
                if isRunning { ProgressView().controlSize(.small) }
            }
            .disabled(isRunning)
            if let note {
                Text(note).foregroundStyle(.secondary)
            }
            if let failure {
                Text(failure).foregroundStyle(.red).textSelection(.enabled)
            }
            if let result {
                LabeledContent(
                    "Result",
                    value: result.timedOut ? "Timed out" : "Exit \(result.exitCode) in "
                        + "\(result.duration.formatted(.number.precision(.fractionLength(2)))) s"
                )
                if !result.output.isEmpty {
                    Text(result.output).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                if !result.errorOutput.isEmpty {
                    Text(result.errorOutput)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func send(_ command: RunnerCommand) async {
        isRunning = true
        defer { isRunning = false }
        failure = nil
        note = nil
        do {
            switch try await client.send(command, timeout: timeout + 10) {
            case .snippet(let snippet):
                result = snippet
            case .compiled(let errors):
                result = nil
                if errors.isEmpty {
                    note = "Compiled without errors."
                } else {
                    failure = errors
                }
            case .failure(let message):
                failure = message
            default:
                failure = "Unexpected reply from the runner."
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}
