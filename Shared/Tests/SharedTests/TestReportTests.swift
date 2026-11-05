import Foundation
@testable import Shared
import Testing

struct TestReportTests {
    private func report(_ results: [(String, Bool)], issues: [ValidationIssue] = []) -> TestReport {
        TestReport(
            automationID: "x",
            ranAt: Date(),
            issues: issues,
            results: results.map { .init(name: $0.0, passed: $0.1, message: "") }
        )
    }

    @Test func onlyHarnessFailuresAllowInstallingAnyway() {
        let failing = report([("tests[0] unit, step 0", true), ("tests[1] harness (direct call)", false)])
        #expect(!failing.passed)
        #expect(failing.failsOnlyHarnessTests)
    }

    @Test func otherFailuresOrErrorsDoNot() {
        let unitFailure = report([("tests[0] unit, step 0", false), ("tests[1] harness (focus)", false)])
        #expect(!unitFailure.failsOnlyHarnessTests)

        let withError = report(
            [("tests[1] harness (direct call)", false)],
            issues: [ValidationIssue(.error, "steps[0]", "bad")]
        )
        #expect(!withError.failsOnlyHarnessTests)

        let passing = report([("tests[1] harness (direct call)", true)])
        #expect(!passing.failsOnlyHarnessTests)
    }
}
