import Foundation
import os
import Shared

/// M6: consecutive-failure tracking and the broken notification.
extension RunnerCore {
    func loadFailureStreaks() {
        let runs = store.recentRuns(limit: 2_000)
        failureStreaks = manifests.values.reduce(into: [:]) { streaks, manifest in
            streaks[manifest.id] = FailureMonitor.streak(
                automationID: manifest.id, version: manifest.version, runs: runs
            )
        }
    }

    /// Updates the streak after a run of an installed automation. The run that makes it
    /// broken posts one notification; later failures stay quiet until it works again.
    func trackFailures(_ record: RunRecord, manifest: AutomationManifest) {
        guard let installed = manifests[manifest.id], installed.version == record.version else { return }
        let before = failureStreaks[manifest.id] ?? FailureStreak()
        let after = FailureMonitor.updated(before, with: record)
        guard after != before else { return }
        failureStreaks[manifest.id] = after
        state.automations = summaries()
        syncIndex()
        if FailureMonitor.justBroke(before: before, after: after) {
            logger.error("\(manifest.id, privacy: .public) is broken: \(after.count) failed runs in a row")
            FailureNotifier.postBroken(name: manifest.name, failures: after.count, lastError: after.lastError)
        }
    }
}
