import Foundation
@testable import Shared
import Testing

/// Sweep 2: running copySelection, pressKeys and askText, and a user cancel stopping the run
/// as skipped rather than failed.
struct InteractiveRunTests {
    /// 2024-12-30T12:00:00Z
    private static let clock = Date(timeIntervalSince1970: 1_735_560_000)

    /// An environment whose scripts end as if the user pressed Cancel in a dialog.
    private struct CancellingScriptEnvironment: AutomationEnvironment {
        func now() -> Date { InteractiveRunTests.clock }
        func typeText(_ text: String) async throws {
            throw AutomationError.system("typeText must not run after a cancel")
        }
        func pasteText(_ text: String) async throws {}
        func readClipboard() async throws -> String { "" }
        func writeClipboard(_ text: String) async throws {}
        func notify(title: String, text: String) async throws {}
        func openURL(_ url: URL) async throws {}
        func launchApp(_ app: String) async throws {}
        func sleep(seconds: Double) async throws {}
        func runScript(_ request: ScriptRequest) async throws -> String {
            throw AutomationError.cancelledByUser
        }
    }

    private func manifest(_ steps: [Step]) -> AutomationManifest {
        AutomationManifest(id: "sample", name: "Sample", trigger: .manual, steps: steps, permissions: [.accessibility])
    }

    // MARK: copySelection

    @Test func selectionFlowsToLaterSteps() async {
        let environment = RecordingEnvironment(now: Self.clock, selection: "hello world")
        let engine = AutomationEngine(environment: environment)
        let record = await engine.run(manifest([
            Step(.primitive(.copySelection), output: "selection"),
            Step(.primitive(.pasteText("[{{selection}}]")))
        ]), cause: .hotkey)

        #expect(record.outcome == .succeeded, "\(record)")
        #expect(await environment.selectionCopies == 1)
        #expect(await environment.pasted == ["[hello world]"])
        #expect(record.steps.map { $0.output } == ["hello world", "[hello world]"])
    }

    @Test func emptySelectionFailsTheStep() async {
        let environment = RecordingEnvironment(now: Self.clock)
        let engine = AutomationEngine(environment: environment)
        let record = await engine.run(manifest([
            Step(.primitive(.copySelection), output: "selection"),
            Step(.primitive(.pasteText("{{selection}}")))
        ]), cause: .hotkey)

        #expect(record.outcome == .failed)
        #expect(record.error?.contains("Nothing is selected") == true)
        #expect(record.steps.count == 1)
        #expect(await environment.pasted.isEmpty)
    }

    // MARK: pressKeys

    @Test func pressKeysPressesTheParsedCombo() async throws {
        let environment = RecordingEnvironment(now: Self.clock)
        let engine = AutomationEngine(environment: environment)
        let output = try await engine.runStep(Step(.primitive(.pressKeys("cmd+shift+4"))), variables: [:])

        #expect(output == "cmd+shift+4")
        let expected = KeyCombo(modifiers: [.cmd, .shift], key: "4", keyCode: 0x15)
        #expect(await environment.pressedKeys == [expected])
    }

    @Test func unknownKeyFailsTheRun() async {
        let environment = RecordingEnvironment(now: Self.clock)
        let engine = AutomationEngine(environment: environment)
        let record = await engine.run(manifest([Step(.primitive(.pressKeys("cmd+hyper")))]), cause: .manual)

        #expect(record.outcome == .failed)
        #expect(record.error?.contains("hyper") == true)
        #expect(await environment.pressedKeys.isEmpty)
    }

    // MARK: askText

    @Test func askTextReturnsTheAnswer() async {
        let environment = RecordingEnvironment(now: Self.clock, clipboard: "draft.txt", answer: "final.txt")
        let engine = AutomationEngine(environment: environment)
        let record = await engine.run(manifest([
            Step(.primitive(.readClipboard), output: "file"),
            Step(.primitive(.askText(prompt: "Rename {{file}} to?", defaultValue: "{{file}}")), output: "name"),
            Step(.primitive(.typeText("{{name}}")))
        ]), cause: .hotkey)

        #expect(record.outcome == .succeeded, "\(record)")
        #expect(await environment.prompts == ["Rename draft.txt to?"])
        #expect(await environment.typed == ["final.txt"])
    }

    @Test func askTextWithoutAnAnswerUsesTheDefault() async throws {
        let environment = RecordingEnvironment(now: Self.clock, clipboard: "draft.txt")
        let engine = AutomationEngine(environment: environment)
        let steps = manifest([
            Step(.primitive(.readClipboard), output: "file"),
            Step(.primitive(.askText(prompt: "Rename?", defaultValue: "{{file}}")))
        ])
        #expect(try await engine.output(ofStep: 1, in: steps) == "draft.txt")
    }

    @Test func cancelledAskTextSkipsTheRun() async {
        let environment = RecordingEnvironment(now: Self.clock, cancelsPrompts: true)
        let engine = AutomationEngine(environment: environment)
        let record = await engine.run(manifest([
            Step(.primitive(.askText(prompt: "Name?", defaultValue: nil)), output: "name"),
            Step(.primitive(.typeText("{{name}}")))
        ]), cause: .hotkey)

        #expect(record.outcome == .skipped)
        #expect(record.error == "Cancelled by the user")
        #expect(record.steps.count == 1)
        #expect(record.steps.first?.outcome == .skipped)
        #expect(record.steps.first?.error == "Cancelled by the user")
        #expect(await environment.prompts == ["Name?"])
        #expect(await environment.typed.isEmpty)
    }

    @Test func cancelledAskTextThrowsFromRunStep() async {
        let engine = AutomationEngine(environment: RecordingEnvironment(now: Self.clock, cancelsPrompts: true))
        await #expect(throws: AutomationError.cancelledByUser) {
            try await engine.runStep(Step(.primitive(.askText(prompt: "Name?", defaultValue: nil))), variables: [:])
        }
    }

    // MARK: Script cancel

    @Test func cancelledScriptSkipsTheRun() async {
        let engine = AutomationEngine(environment: CancellingScriptEnvironment())
        let record = await engine.run(manifest([
            Step(.applescript(ScriptSource(source: "display dialog \"Go?\""))),
            Step(.primitive(.typeText("never")))
        ]), cause: .hotkey)

        #expect(record.outcome == .skipped)
        #expect(record.error == "Cancelled by the user")
        #expect(record.steps.map { $0.outcome } == [.skipped])
    }

    @Test func recognizesUserCancelInScriptErrors() {
        #expect(AutomationError.isUserCancel(scriptError: "script.applescript: execution error: User canceled. (-128)"))
        #expect(AutomationError.isUserCancel(scriptError: "Error: Error: User canceled. (-128)"))
        #expect(!AutomationError.isUserCancel(scriptError: "execution error: Not authorized. (-1743)"))
        #expect(!AutomationError.isUserCancel(scriptError: ""))
    }

    // MARK: Failure monitoring

    @Test func cancelledRunDoesNotCountAsAFailure() async {
        let engine = AutomationEngine(environment: RecordingEnvironment(now: Self.clock, cancelsPrompts: true))
        let cancelled = await engine.run(
            manifest([Step(.primitive(.askText(prompt: "Name?", defaultValue: nil)))]), cause: .hotkey
        )
        #expect(cancelled.outcome == .skipped)

        let failed = RunRecord(
            automationID: "sample", version: 1, cause: .hotkey, startedAt: Self.clock, duration: 0.1,
            outcome: .failed, error: "boom", steps: []
        )
        let twoFailures = FailureStreak(failures: 2, lastError: "boom", lastFailureAt: Self.clock)
        #expect(FailureMonitor.updated(twoFailures, with: cancelled) == twoFailures)
        #expect(FailureMonitor.updated(FailureStreak(), with: cancelled) == FailureStreak())

        let runs = [cancelled, failed, cancelled, failed, cancelled]
        let streak = FailureMonitor.streak(automationID: "sample", version: 1, runs: runs)
        #expect(streak.failures == 2)
        #expect(!streak.isBroken)
    }
}
