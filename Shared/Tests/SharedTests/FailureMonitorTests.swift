import Foundation
@testable import Shared
import Testing

struct FailureMonitorTests {
    private func run(
        _ outcome: RunRecord.Outcome,
        cause: RunRecord.Cause = .hotkey,
        version: Int = 1,
        id: String = "demo",
        error: String? = nil,
        minutesAgo: Double = 0
    ) -> RunRecord {
        RunRecord(
            automationID: id,
            version: version,
            cause: cause,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000 - minutesAgo * 60),
            duration: 0.1,
            outcome: outcome,
            error: error ?? (outcome == .failed ? "boom" : nil),
            steps: []
        )
    }

    @Test func countsFailuresUntilTheLastSuccess() {
        let runs = [
            run(.failed, error: "newest", minutesAgo: 0),
            run(.failed, minutesAgo: 1),
            run(.succeeded, minutesAgo: 2),
            run(.failed, minutesAgo: 3)
        ]
        let streak = FailureMonitor.streak(automationID: "demo", version: 1, runs: runs)
        #expect(streak.failures == 2)
        #expect(streak.lastError == "newest")
        #expect(!streak.isBroken)
    }

    @Test func ignoresTestsSkipsOtherIDsAndOtherVersions() {
        let runs = [
            run(.failed),
            run(.succeeded, cause: .test),
            run(.skipped),
            run(.succeeded, id: "other"),
            run(.succeeded, version: 2),
            run(.failed),
            run(.failed)
        ]
        let streak = FailureMonitor.streak(automationID: "demo", version: 1, runs: runs)
        #expect(streak.failures == 3)
        #expect(streak.isBroken)
        #expect(FailureMonitor.streak(automationID: "demo", version: 2, runs: runs).failures == 0)
    }

    @Test func updatedTracksTheThresholdCrossingOnce() {
        var streak = FailureStreak()
        var crossings = 0
        for _ in 0..<5 {
            let next = FailureMonitor.updated(streak, with: run(.failed))
            if FailureMonitor.justBroke(before: streak, after: next) { crossings += 1 }
            streak = next
        }
        #expect(streak.failures == 5)
        #expect(crossings == 1)

        #expect(FailureMonitor.updated(streak, with: run(.failed, cause: .test)) == streak)
        #expect(FailureMonitor.updated(streak, with: run(.skipped)) == streak)
        #expect(FailureMonitor.updated(streak, with: run(.succeeded)) == FailureStreak())
    }

    @Test func repeatedFailuresMakeTheSummaryBroken() throws {
        let manifest = try AutomationManifest.decode(from: Data(ExampleManifests.insertISODate.utf8))
        let healthy = AutomationSummary(
            manifest: manifest, issues: [], registrationError: nil, folderPath: "/tmp/x",
            failureStreak: FailureStreak(failures: 2)
        )
        #expect(healthy.status == .active)

        let broken = AutomationSummary(
            manifest: manifest, issues: [], registrationError: nil, folderPath: "/tmp/x",
            failureStreak: FailureStreak(failures: 3, lastError: "boom")
        )
        #expect(broken.status == .broken)

        let disabled = AutomationSummary(
            manifest: manifest, issues: [], registrationError: nil, folderPath: "/tmp/x",
            enabled: false, failureStreak: FailureStreak(failures: 3)
        )
        #expect(disabled.status == .disabled)

        let decoded = try XPCCoding.decode(AutomationSummary.self, from: XPCCoding.encode(broken))
        #expect(decoded == broken)
    }

    @Test func fixRequestNamesTheAutomationItsFailuresAndTheNextVersion() throws {
        let manifest = try AutomationManifest.decode(from: Data(ExampleManifests.insertISODate.utf8))
        let summary = AutomationSummary(
            manifest: manifest, issues: [], registrationError: nil, folderPath: "/tmp/x",
            failureStreak: FailureStreak(failures: 3, lastError: "Step 1 failed")
        )
        let runs = [
            run(.failed, id: "insert-iso-date", error: "Step 1 (primitive): not allowed"),
            run(.succeeded, id: "insert-iso-date")
        ]
        let message = FixRequest.message(for: summary, recentRuns: runs)
        #expect(message.contains("insert-iso-date"))
        #expect(message.contains("failed 3 time(s) in a row"))
        #expect(message.contains("Step 1 (primitive): not allowed"))
        #expect(message.contains("version 2"))
        #expect(message.contains("read_automation"))
    }
}
