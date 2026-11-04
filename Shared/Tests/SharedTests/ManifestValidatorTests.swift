import Foundation
@testable import Shared
import Testing

struct ManifestValidatorTests {
    private static let passingTest = ManifestTest.unit(.init(step: 0, expect: "anything"))

    private func manifest(
        id: String = "sample",
        trigger: Trigger = .manual,
        steps: [Step],
        permissions: [Permission] = [],
        tests: [ManifestTest] = [ManifestValidatorTests.passingTest]
    ) -> AutomationManifest {
        AutomationManifest(
            id: id, name: "Sample", trigger: trigger, steps: steps, permissions: permissions, tests: tests
        )
    }

    private func errors(_ issues: [ValidationIssue]) -> [ValidationIssue] {
        issues.filter { $0.severity == .error }
    }

    private static let clipboardStep = Step(.primitive(.readClipboard), output: "clip")

    @Test func dateExampleHasNoErrors() throws {
        let example = try AutomationManifest.decode(from: Data(ExampleManifests.insertISODate.utf8))
        let issues = ManifestValidator.validate(example)
        #expect(errors(issues).isEmpty, "\(issues)")
        #expect(!ManifestValidator.hasErrors(issues))
    }

    @Test func minimalManifestHasNoIssues() {
        #expect(ManifestValidator.validate(manifest(steps: [Self.clipboardStep])).isEmpty)
    }

    @Test func badIDIsAnError() {
        let issues = ManifestValidator.validate(manifest(id: "Insert Date", steps: [Self.clipboardStep]))
        #expect(errors(issues).map(\.location) == ["id"])
        #expect(ManifestValidator.hasErrors(issues))
    }

    @Test func emptyStepsIsAnError() {
        let issues = ManifestValidator.validate(manifest(steps: [], tests: [.harness(.init(expectText: "x"))]))
        #expect(errors(issues).map(\.location) == ["steps"])
    }

    @Test func undefinedReferenceIsAnError() {
        let issues = ManifestValidator.validate(manifest(
            steps: [Step(.primitive(.writeClipboard("{{missing}}")))]
        ))
        let found = errors(issues)
        #expect(found.count == 1)
        #expect(found.first?.location == "steps[0]")
        #expect(found.first?.message.contains("{{missing}}") == true)
    }

    @Test func referenceToLaterStepIsAnError() {
        let issues = ManifestValidator.validate(manifest(steps: [
            Step(.primitive(.writeClipboard("{{clip}}"))),
            Self.clipboardStep
        ]))
        #expect(errors(issues).map(\.location) == ["steps[0]"])
    }

    @Test func todayIsNotAReference() {
        let issues = ManifestValidator.validate(manifest(
            steps: [Step(.primitive(.writeClipboard("{{today:yyyy}}")))]
        ))
        #expect(errors(issues).isEmpty)
    }

    @Test func typeTextNeedsAccessibility() {
        let steps = [Step(.primitive(.typeText("hello")))]
        let missing = ManifestValidator.validate(manifest(steps: steps))
        #expect(errors(missing).map(\.location) == ["steps[0]"])
        #expect(errors(missing).first?.message.contains("accessibility") == true)

        let declared = ManifestValidator.validate(manifest(steps: steps, permissions: [.accessibility]))
        #expect(errors(declared).isEmpty)
    }

    @Test func unitTestStepOutOfRangeIsAnError() {
        let issues = ManifestValidator.validate(manifest(
            steps: [Self.clipboardStep],
            tests: [.unit(.init(step: 3, expect: "x"))]
        ))
        #expect(errors(issues).map(\.location) == ["tests[0]"])
    }

    @Test func unknownHotkeyKeyIsAnError() {
        let issues = ManifestValidator.validate(manifest(
            trigger: .hotkey(Hotkey(key: "Hyper", modifiers: [.cmd])),
            steps: [Self.clipboardStep]
        ))
        #expect(errors(issues).map(\.location) == ["trigger.key"])
    }

    @Test func hotkeyWithoutModifiersIsAWarning() {
        let issues = ManifestValidator.validate(manifest(
            trigger: .hotkey(Hotkey(key: "D", modifiers: [])),
            steps: [Self.clipboardStep]
        ))
        #expect(errors(issues).isEmpty)
        #expect(issues.map(\.location) == ["trigger.modifiers"])
    }

    @Test func appleScriptStepNeedsSupport() {
        let script = Step(.applescript(ScriptSource(source: "return 1")), output: "result")
        let unsupported = ManifestValidator.validate(manifest(steps: [script]))
        #expect(errors(unsupported).map(\.location) == ["steps[0]"])
        #expect(errors(unsupported).first?.message.contains("applescript") == true)

        let supported = ManifestValidator.validate(
            manifest(steps: [script]),
            supportedStepTypes: ["primitive", "applescript"]
        )
        #expect(errors(supported).isEmpty)
    }

    @Test func nonPositiveTimeoutIsAnError() {
        let issues = ManifestValidator.validate(manifest(steps: [Step(.primitive(.readClipboard), timeout: 0)]))
        #expect(errors(issues).map(\.location) == ["steps[0]"])
    }

    @Test func noTestsIsOnlyAWarning() {
        let issues = ManifestValidator.validate(manifest(steps: [Self.clipboardStep], tests: []))
        #expect(errors(issues).isEmpty)
        #expect(issues == [ValidationIssue(.warning, "tests", "No tests declared.")])
        #expect(!ManifestValidator.hasErrors(issues))
    }
}
