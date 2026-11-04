import Foundation
@testable import Shared
import Testing

struct RunnerCommandsTests {
    private static let sampleManifest = AutomationManifest(
        id: "sample",
        name: "Sample",
        description: "A sample.",
        trigger: .hotkey(Hotkey(key: "D", modifiers: [.ctrl, .cmd])),
        steps: [Step(.primitive(.readClipboard), output: "clip")],
        permissions: [.accessibility],
        tests: [.unit(.init(step: 0, expect: ""))]
    )

    private static let sampleRecord = RunRecord(
        automationID: "sample",
        version: 1,
        cause: .hotkey,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        duration: 0.5,
        outcome: .failed,
        error: "Step 0 (primitive): boom",
        steps: [.init(index: 0, type: "primitive", outcome: .failed, output: nil, error: "boom", duration: 0.25)]
    )

    private func roundTrip<Message: Codable>(_ message: Message) throws -> Message {
        try XPCCoding.decode(Message.self, from: XPCCoding.encode(message))
    }

    @Test func everyCommandRoundTrips() throws {
        let commands: [RunnerCommand] = [
            .listAutomations,
            .installFromFile(path: "/tmp/sample/manifest.json"),
            .installManifest(Data(ExampleManifests.insertISODate.utf8)),
            .remove(id: "sample"),
            .run(id: "sample"),
            .test(id: "sample"),
            .recentRuns(limit: 25),
            .setPaused(true),
            .setPaused(false)
        ]
        for command in commands {
            #expect(try roundTrip(command) == command)
        }
    }

    @Test func repliesRoundTrip() throws {
        let issue = ValidationIssue(.warning, "tests", "No tests declared.")
        let summary = AutomationSummary(
            manifest: Self.sampleManifest, issues: [issue], registrationError: nil, folderPath: "/tmp/sample"
        )
        let replies: [RunnerReply] = [
            .automations([summary], paused: true),
            .automations([], paused: false),
            .installed(InstallReport(automationID: "sample", installed: true, issues: [issue], message: "Installed")),
            .installed(InstallReport(automationID: nil, installed: false, issues: [], message: "Bad JSON")),
            .removed(id: "sample"),
            .ran(Self.sampleRecord),
            .tested(TestReport(
                automationID: "sample",
                ranAt: Date(timeIntervalSince1970: 1_700_000_500),
                issues: [issue],
                results: [.init(name: "tests[0] unit, step 0", passed: true, message: "Got \"\"")]
            )),
            .runs([Self.sampleRecord]),
            .done,
            .failure("Something went wrong")
        ]
        for reply in replies {
            #expect(try roundTrip(reply) == reply)
        }
    }

    @Test func summaryReflectsManifest() {
        let summary = AutomationSummary(
            manifest: Self.sampleManifest, issues: [], registrationError: nil, folderPath: "/tmp/sample"
        )
        #expect(summary.id == "sample")
        #expect(summary.name == "Sample")
        #expect(summary.description == "A sample.")
        #expect(summary.trigger == "Hotkey ⌃⌘D")
        #expect(summary.stepTypes == ["primitive"])
        #expect(summary.permissions == [.accessibility])
        #expect(summary.testCount == 1)
        #expect(summary.version == 1)
        #expect(summary.folderPath == "/tmp/sample")
        #expect(summary.isActive)
    }

    @Test func summaryIsInactiveWithRegistrationError() {
        let summary = AutomationSummary(
            manifest: Self.sampleManifest, issues: [], registrationError: "Hotkey taken", folderPath: "/tmp/sample"
        )
        #expect(!summary.isActive)
    }

    @Test func summaryIsInactiveWithErrorIssue() {
        let summary = AutomationSummary(
            manifest: Self.sampleManifest,
            issues: [ValidationIssue(.error, "id", "Bad id.")],
            registrationError: nil,
            folderPath: "/tmp/sample"
        )
        #expect(!summary.isActive)
    }

    @Test func summaryStaysActiveWithWarningsOnly() {
        let summary = AutomationSummary(
            manifest: Self.sampleManifest,
            issues: [ValidationIssue(.warning, "tests", "No tests declared.")],
            registrationError: nil,
            folderPath: "/tmp/sample"
        )
        #expect(summary.isActive)
    }

    @Test func testReportPassed() {
        let passing = TestReport(
            automationID: "sample",
            ranAt: Date(timeIntervalSince1970: 0),
            issues: [ValidationIssue(.warning, "tests", "No tests declared.")],
            results: [.init(name: "a", passed: true, message: "")]
        )
        #expect(passing.passed)

        var failing = passing
        failing.results.append(.init(name: "b", passed: false, message: "Expected"))
        #expect(!failing.passed)

        var invalid = passing
        invalid.issues.append(ValidationIssue(.error, "id", "Bad id."))
        #expect(!invalid.passed)
    }
}
