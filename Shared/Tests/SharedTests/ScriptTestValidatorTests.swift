import Foundation
@testable import Shared
import Testing

struct ScriptTestValidatorTests {
    private static let shellStep = Step(.shell(ScriptSource(source: "echo hi")), output: "greeting")
    private static let finderStep = Step(.applescript(ScriptSource(
        source: "tell application \"Finder\" to get name of startup disk"
    )))

    private func manifest(steps: [Step], tests: [ManifestTest]) -> AutomationManifest {
        AutomationManifest(
            id: "sample",
            name: "Sample",
            trigger: .manual,
            steps: steps,
            permissions: [.automation("com.apple.finder")],
            tests: tests
        )
    }

    private func testErrors(_ manifest: AutomationManifest, folder: URL? = nil) -> [ValidationIssue] {
        ManifestValidator.validate(manifest, folder: folder)
            .filter { $0.severity == .error && $0.location.hasPrefix("tests") }
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ScriptTestValidatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: url.appending(path: "tests/fixtures/inbox"), withIntermediateDirectories: true
        )
        return url
    }

    @Test func validScriptTestHasNoErrors() {
        let test = ManifestTest.script(.init(step: 0, expect: "hi"))
        #expect(testErrors(manifest(steps: [Self.shellStep], tests: [test])).isEmpty)
    }

    @Test func missingStepIsAnError() {
        let test = ManifestTest.script(.init(step: 3, expect: "hi"))
        let errors = testErrors(manifest(steps: [Self.shellStep], tests: [test]))
        #expect(errors.map { $0.location } == ["tests[0]"])
        #expect(errors.first?.message.contains("does not exist") == true)
    }

    @Test func nonScriptStepIsAnError() {
        let test = ManifestTest.script(.init(step: 0, expect: "x"))
        let errors = testErrors(manifest(steps: [Step(.primitive(.readClipboard))], tests: [test]))
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("primitive") == true)
    }

    @Test func appleEventsStepIsAnError() {
        let test = ManifestTest.script(.init(step: 0, expectContains: "Macintosh"))
        let errors = testErrors(manifest(steps: [Self.finderStep], tests: [test]))
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("Finder") == true)
        #expect(errors.first?.message.contains("run_snippet") == true)
    }

    @Test func noExpectationIsAnError() {
        let test = ManifestTest.script(.init(step: 0, inputs: ["a": "b"]))
        let errors = testErrors(manifest(steps: [Self.shellStep], tests: [test]))
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("expectContains") == true)
    }

    @Test func expectWithVariableIsAnError() {
        let test = ManifestTest.script(.init(step: 0, expect: "{{greeting}}"))
        #expect(testErrors(manifest(steps: [Self.shellStep], tests: [test])).count == 1)
        let today = ManifestTest.script(.init(step: 0, expect: "{{today:yyyy-MM-dd}}"))
        #expect(testErrors(manifest(steps: [Self.shellStep], tests: [today])).isEmpty)
    }

    @Test func unsafePathsAreErrors() {
        for path in ["/tmp/x", "../x", "a/../../x", "~/Downloads", ""] {
            let fixtures = ManifestTest.script(.init(step: 0, fixtures: path, expect: "hi"))
            #expect(testErrors(manifest(steps: [Self.shellStep], tests: [fixtures])).count == 1, "\(path)")
            let files = ManifestTest.script(.init(step: 0, expectFiles: [path]))
            #expect(testErrors(manifest(steps: [Self.shellStep], tests: [files])).count == 1, "\(path)")
            let missing = ManifestTest.script(.init(step: 0, expectMissing: [path]))
            #expect(testErrors(manifest(steps: [Self.shellStep], tests: [missing])).count == 1, "\(path)")
        }
    }

    @Test func fixturesMustExistWhenFolderIsKnown() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let present = ManifestTest.script(.init(step: 0, fixtures: "tests/fixtures/inbox", expect: "hi"))
        #expect(testErrors(manifest(steps: [Self.shellStep], tests: [present]), folder: folder).isEmpty)

        let absent = ManifestTest.script(.init(step: 0, fixtures: "tests/fixtures/nope", expect: "hi"))
        let errors = testErrors(manifest(steps: [Self.shellStep], tests: [absent]), folder: folder)
        #expect(errors.count == 1)
        #expect(errors.first?.message.contains("does not exist") == true)
        // Without a folder the path can only be checked for shape.
        #expect(testErrors(manifest(steps: [Self.shellStep], tests: [absent])).isEmpty)
    }

    @Test func selectAllWithoutSetupTextWarns() {
        let test = ManifestTest.harness(.init(select: .all, expectText: "x"))
        let issues = ManifestValidator.validate(manifest(steps: [Self.shellStep], tests: [test]))
        #expect(issues.contains { $0.severity == .warning && $0.location == "tests[0]" })
        #expect(!ManifestValidator.hasErrors(issues))
    }
}
