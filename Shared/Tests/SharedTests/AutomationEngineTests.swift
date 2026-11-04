import Foundation
@testable import Shared
import Testing

struct AutomationEngineTests {
    /// 2024-12-30T12:00:00Z
    private static let clock = Date(timeIntervalSince1970: 1_735_560_000)

    /// An environment whose `sleep` really sleeps, for timeout tests.
    private struct SleepingEnvironment: AutomationEnvironment {
        func now() -> Date { Date() }
        func typeText(_ text: String) async throws {}
        func pasteText(_ text: String) async throws {}
        func readClipboard() async throws -> String { "" }
        func writeClipboard(_ text: String) async throws {}
        func notify(title: String, text: String) async throws {}
        func openURL(_ url: URL) async throws {}
        func launchApp(_ app: String) async throws {}
        func sleep(seconds: Double) async throws {
            try await Task.sleep(for: .seconds(seconds))
        }
        func runScript(_ request: ScriptRequest) async throws -> String { "" }
    }

    private func dateExample() throws -> AutomationManifest {
        try AutomationManifest.decode(from: Data(ExampleManifests.insertISODate.utf8))
    }

    private func manifest(_ steps: [Step], tests: [ManifestTest] = []) -> AutomationManifest {
        AutomationManifest(id: "sample", name: "Sample", trigger: .manual, steps: steps, tests: tests)
    }

    @Test func runsDateExample() async throws {
        let environment = RecordingEnvironment(now: Self.clock)
        let engine = AutomationEngine(environment: environment)
        let example = try dateExample()
        let record = await engine.run(example, cause: .manual)

        let expected = DateText.format(Self.clock, pattern: "yyyy-MM-dd")
        #expect(await environment.typed == [expected])
        #expect(await environment.pasted.isEmpty)
        #expect(record.outcome == .succeeded)
        #expect(record.error == nil)
        #expect(record.automationID == "insert-iso-date")
        #expect(record.version == 1)
        #expect(record.cause == .manual)
        #expect(record.steps.count == 2)
        #expect(record.steps.map(\.outcome) == [.succeeded, .succeeded])
        #expect(record.steps.map(\.type) == ["primitive", "primitive"])
        #expect(record.steps.map(\.index) == [0, 1])
        #expect(record.steps.map(\.output) == [expected, expected])
    }

    @Test func clipboardFlowsThroughTemplates() async {
        let environment = RecordingEnvironment(now: Self.clock, clipboard: "hello")
        let engine = AutomationEngine(environment: environment)
        let record = await engine.run(manifest([
            Step(.primitive(.readClipboard), output: "clip"),
            Step(.primitive(.writeClipboard("[{{clip}}]")))
        ]), cause: .test)

        #expect(record.outcome == .succeeded)
        #expect(await environment.clipboard == "[hello]")
        #expect(record.steps.map(\.output) == ["hello", "[hello]"])
    }

    @Test func recordsOtherPrimitives() async {
        let environment = RecordingEnvironment(now: Self.clock)
        let engine = AutomationEngine(environment: environment)
        let record = await engine.run(manifest([
            Step(.primitive(.pasteText("pasted"))),
            Step(.primitive(.notify(title: nil, text: "done"))),
            Step(.primitive(.openURL("https://example.com/a"))),
            Step(.primitive(.launchApp("com.apple.TextEdit"))),
            Step(.primitive(.delay(seconds: 1.5)))
        ]), cause: .test)

        #expect(record.outcome == .succeeded)
        #expect(await environment.pasted == ["pasted"])
        #expect(await environment.notifications.map { $0.text } == ["done"])
        #expect(await environment.notifications.map { $0.title } == ["Automation Agent"])
        #expect(await environment.openedURLs.map(\.absoluteString) == ["https://example.com/a"])
        #expect(await environment.launchedApps == ["com.apple.TextEdit"])
        #expect(await environment.slept == [1.5])
    }

    @Test func failingStepStopsTheRun() async {
        let environment = RecordingEnvironment(now: Self.clock)
        let engine = AutomationEngine(environment: environment)
        let record = await engine.run(manifest([
            Step(.primitive(.openURL("not a url"))),
            Step(.primitive(.typeText("never")))
        ]), cause: .hotkey)

        #expect(record.outcome == .failed)
        #expect(record.error != nil)
        #expect(record.steps.count == 1)
        #expect(record.steps.first?.outcome == .failed)
        #expect(record.steps.first?.error != nil)
        #expect(await environment.typed.isEmpty)
        #expect(await environment.openedURLs.isEmpty)
    }

    @Test func undefinedVariableFailsTheRun() async {
        let engine = AutomationEngine(environment: RecordingEnvironment(now: Self.clock))
        let record = await engine.run(manifest([Step(.primitive(.writeClipboard("{{nope}}")))]), cause: .test)
        #expect(record.outcome == .failed)
        #expect(record.error?.contains("nope") == true)
    }

    @Test func unsupportedStepFailsTheRun() async {
        let environment = RecordingEnvironment(now: Self.clock)
        let engine = AutomationEngine(environment: environment)
        let record = await engine.run(manifest([
            Step(.accessibility(action: "click")),
            Step(.primitive(.typeText("never")))
        ]), cause: .manual)

        #expect(record.outcome == .failed)
        #expect(record.error?.contains("ax") == true)
        #expect(record.steps.count == 1)
        #expect(record.steps.first?.type == "ax")
        #expect(await environment.typed.isEmpty)
    }

    @Test func unsupportedStepThrowsFromRunStep() async {
        let engine = AutomationEngine(environment: RecordingEnvironment(now: Self.clock))
        await #expect(throws: AutomationError.unsupportedStep("ax")) {
            try await engine.runStep(Step(.accessibility(action: "click")), variables: [:])
        }
    }

    @Test func scriptStepsReceiveEarlierOutputsAndFolder() async throws {
        let environment = RecordingEnvironment(
            now: Self.clock,
            clipboard: "a b c",
            scriptOutputs: ["count.sh": "3", "return \"hi\"": "hi"]
        )
        let engine = AutomationEngine(environment: environment)
        var automation = manifest([
            Step(.primitive(.readClipboard), output: "text"),
            Step(.shell(ScriptSource(file: "scripts/count.sh")), output: "count", timeout: 4),
            Step(.applescript(ScriptSource(source: "return \"hi\"")), output: "greeting"),
            Step(.shortcut(name: "Make PDF", input: "{{text}}!"), output: "pdf"),
            Step(.primitive(.writeClipboard("{{greeting}} {{count}}")))
        ])
        automation.permissions = [.automation("com.apple.finder")]
        let folder = URL(filePath: "/tmp/automation")

        let record = await engine.run(automation, cause: .manual, folder: folder)
        #expect(record.outcome == .succeeded, "\(record)")
        #expect(await environment.clipboard == "hi 3")

        let scripts = await environment.scripts
        #expect(scripts.map(\.language) == [.shell, .applescript, .shortcut])
        #expect(scripts[0].file == folder.appending(path: "scripts/count.sh"))
        #expect(scripts[0].variables == ["text": "a b c"])
        #expect(scripts[0].timeout == 4)
        #expect(scripts[0].workingDirectory == folder)
        #expect(scripts[1].declaredPermissions == [.automation("com.apple.finder")])
        #expect(scripts[1].variables == ["text": "a b c", "count": "3"])
        #expect(scripts[2].shortcutName == "Make PDF")
        #expect(scripts[2].shortcutInput == "a b c!")
    }

    @Test func scriptFileWithoutFolderFails() async {
        let engine = AutomationEngine(environment: RecordingEnvironment(now: Self.clock))
        let record = await engine.run(manifest([Step(.shell(ScriptSource(file: "scripts/x.sh")))]), cause: .manual)
        #expect(record.outcome == .failed)
    }

    @Test func slowStepTimesOut() async {
        let engine = AutomationEngine(environment: SleepingEnvironment())
        let step = Step(.primitive(.delay(seconds: 30)), timeout: 0.2)
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: AutomationError.timedOut(seconds: 0.2)) {
            try await engine.runStep(step, variables: [:])
        }
        // The step would sleep 30 s; the timeout must cut it short. The bound is loose because
        // the whole suite runs in parallel and can delay scheduling by a few seconds.
        #expect(clock.now - start < .seconds(10))
    }

    @Test func timedOutStepFailsTheRun() async {
        let engine = AutomationEngine(environment: SleepingEnvironment())
        let clock = ContinuousClock()
        let start = clock.now
        let record = await engine.run(
            manifest([Step(.primitive(.delay(seconds: 30)), timeout: 0.2)]),
            cause: .test
        )
        // The step would sleep 30 s; the timeout must cut it short. The bound is loose because
        // the whole suite runs in parallel and can delay scheduling by a few seconds.
        #expect(clock.now - start < .seconds(10))
        #expect(record.outcome == .failed)
        #expect(record.steps.first?.error == AutomationError.timedOut(seconds: 0.2).localizedDescription)
    }

    @Test func outputOfStepReturnsThatStepsOutput() async throws {
        let environment = RecordingEnvironment(now: Self.clock, clipboard: "seed")
        let engine = AutomationEngine(environment: environment)
        let steps = manifest([
            Step(.primitive(.readClipboard), output: "clip"),
            Step(.primitive(.formatDate(pattern: "yyyy")), output: "year"),
            Step(.primitive(.pasteText("{{clip}}-{{year}}")))
        ])
        let year = DateText.format(Self.clock, pattern: "yyyy")

        #expect(try await engine.output(ofStep: 0, in: steps) == "seed")
        #expect(try await engine.output(ofStep: 1, in: steps) == year)
        #expect(await environment.pasted.isEmpty)
        #expect(try await engine.output(ofStep: 2, in: steps) == "seed-\(year)")
        #expect(await environment.pasted == ["seed-\(year)"])
    }

    @Test func outputOfStepInDateExample() async throws {
        let engine = AutomationEngine(environment: RecordingEnvironment(now: Self.clock))
        let example = try dateExample()
        let expected = DateText.format(Self.clock, pattern: "yyyy-MM-dd")
        #expect(try await engine.output(ofStep: 0, in: example) == expected)
        #expect(try await engine.output(ofStep: 1, in: example) == expected)
    }

    @Test func longOutputIsExcerpted() async {
        let long = String(repeating: "x", count: RunRecord.outputExcerptLimit + 10)
        let engine = AutomationEngine(environment: RecordingEnvironment(now: Self.clock, clipboard: long))
        let record = await engine.run(manifest([Step(.primitive(.readClipboard))]), cause: .test)
        let output = record.steps.first?.output
        #expect(output?.count == RunRecord.outputExcerptLimit + 1)
        #expect(output?.hasSuffix("…") == true)
    }

    // MARK: UnitTestRunner

    @Test func unitTestsOfDateExamplePass() async throws {
        let example = try dateExample()
        let results = await UnitTestRunner.run(example)
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0.passed }, "\(results)")
    }

    @Test func wrongExpectationFails() async {
        let results = await UnitTestRunner.run(manifest(
            [Step(.primitive(.formatDate(pattern: "yyyy")), output: "year")],
            tests: [.unit(.init(step: 0, clock: Self.clock, expect: "1999"))]
        ))
        #expect(results.count == 1)
        let result = results.first
        #expect(result?.passed == false)
        #expect(result?.message.contains("Expected") == true)
    }

    @Test func unitTestUsesClipboardAndToday() async {
        let results = await UnitTestRunner.run(manifest(
            [
                Step(.primitive(.readClipboard), output: "clip"),
                Step(.primitive(.writeClipboard("{{clip}} {{today:yyyy}}")))
            ],
            tests: [
                .unit(.init(step: 1, clock: Self.clock, clipboard: "on", expect: "on {{today:yyyy}}")),
                .harness(.init(expectText: "ignored"))
            ]
        ))
        #expect(results.count == 1)
        #expect(results.first?.passed == true, "\(results)")
    }
}
