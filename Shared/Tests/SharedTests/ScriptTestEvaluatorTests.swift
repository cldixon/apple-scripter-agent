import Foundation
@testable import Shared
import Testing

struct ScriptTestEvaluatorTests {
    private static let now = Date(timeIntervalSince1970: 1_735_560_000) // 2024-12-30T12:00:00Z

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "ScriptTestEvaluatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url.appending(path: "Archive"), withIntermediateDirectories: true)
        try "x".write(to: url.appending(path: "Archive/a.pdf"), atomically: true, encoding: .utf8)
        return url
    }

    private func outcome(_ output: String, exitCode: Int32 = 0, errors: String = "") -> ScriptResult {
        ScriptResult(output: output, errorOutput: errors, exitCode: exitCode, duration: 0.1, timedOut: false)
    }

    private let nowhere = URL(filePath: "/nonexistent/script-test")

    @Test func exactExpectation() {
        let test = ManifestTest.ScriptTest(step: 0, expect: "HELLO")
        #expect(ScriptTestEvaluator.check(test, output: "HELLO", workDirectory: nowhere).isEmpty)
        let failures = ScriptTestEvaluator.check(test, output: "hello", workDirectory: nowhere)
        #expect(failures == [#"Expected "HELLO", got "hello""#])
    }

    @Test func containsExpectation() {
        let test = ManifestTest.ScriptTest(step: 0, expectContains: "moved 2")
        #expect(ScriptTestEvaluator.check(test, output: "moved 2 files", workDirectory: nowhere).isEmpty)
        #expect(ScriptTestEvaluator.check(test, output: "moved 1 file", workDirectory: nowhere).count == 1)
    }

    @Test func todayTemplate() {
        let test = ManifestTest.ScriptTest(step: 0, expect: "Archive-{{today:yyyy}}")
        let expected = "Archive-" + DateText.format(Self.now, pattern: "yyyy")
        #expect(ScriptTestEvaluator.check(test, output: expected, workDirectory: nowhere, now: Self.now).isEmpty)
        #expect(!ScriptTestEvaluator.check(test, output: "Archive-1999", workDirectory: nowhere, now: Self.now).isEmpty)
    }

    @Test func expectedAndMissingFiles() throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let passing = ManifestTest.ScriptTest(
            step: 0, expectFiles: ["Archive/a.pdf", "Archive"], expectMissing: ["a.pdf"]
        )
        #expect(ScriptTestEvaluator.check(passing, output: "", workDirectory: folder).isEmpty)

        let failing = ManifestTest.ScriptTest(step: 0, expectFiles: ["b.pdf"], expectMissing: ["Archive/a.pdf"])
        let failures = ScriptTestEvaluator.check(failing, output: "", workDirectory: folder)
        #expect(failures.count == 2)
        #expect(failures.first?.contains("Archive/a.pdf") == true) // the listing helps the agent

        let escaping = ManifestTest.ScriptTest(step: 0, expectFiles: ["../outside"])
        #expect(ScriptTestEvaluator.check(escaping, output: "", workDirectory: folder).count == 1)
    }

    @Test func everyExpectationMustHold() {
        let test = ManifestTest.ScriptTest(step: 0, expect: "a", expectContains: "b")
        #expect(ScriptTestEvaluator.check(test, output: "a", workDirectory: nowhere).count == 1)
    }

    @Test func resultReportsExitAndTimeout() {
        let test = ManifestTest.ScriptTest(step: 0, expect: "ok")
        let passed = ScriptTestEvaluator.result(name: "t", test: test, outcome: outcome("ok"), workDirectory: nowhere)
        #expect(passed.passed)
        #expect(passed.name == "t")

        let failed = ScriptTestEvaluator.result(
            name: "t", test: test, outcome: outcome("ok", exitCode: 1, errors: "boom"), workDirectory: nowhere
        )
        #expect(!failed.passed)
        #expect(failed.message == "boom")

        let denied = ScriptTestEvaluator.result(
            name: "t",
            test: test,
            outcome: outcome("", exitCode: 1, errors: "zsh: operation not permitted: /x"),
            workDirectory: nowhere
        )
        #expect(denied.message.contains("Script tests run in a sandbox"))

        var slow = outcome("ok")
        slow.timedOut = true
        #expect(!ScriptTestEvaluator.result(name: "t", test: test, outcome: slow, workDirectory: nowhere).passed)
    }
}
