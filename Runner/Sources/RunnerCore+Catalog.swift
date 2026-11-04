import Foundation
import os
import Shared

/// Catalog commands and the SQLite index. Every approved change is one git commit in the
/// automations folder (see `CatalogRepository`); the index follows the folders.
extension RunnerCore {
    // MARK: Commands

    func handleCatalogChange(_ command: RunnerCommand) async -> RunnerReply {
        switch command {
        case .installFromFile(let path):
            let url = URL(filePath: path)
            do {
                let data = try Data(contentsOf: url)
                return .installed(await install(manifestData: data, sourceFolder: url.deletingLastPathComponent()))
            } catch {
                return .failure("Could not read \(path): \(error.localizedDescription)")
            }
        case .installManifest(let data):
            return .installed(await install(manifestData: data, sourceFolder: nil))
        case .remove(let id):
            do {
                let warning = try catalog.remove(id: id)
                reload()
                if let warning { logger.error("\(warning, privacy: .public)") }
                return .removed(id: id)
            } catch {
                return .failure("Could not remove \(id): \(error.localizedDescription)")
            }
        case .setEnabled(let id, let enabled):
            return setEnabled(id: id, enabled: enabled)
        case .rebuildIndex:
            if let problem = rebuildIndex() { return .failure(problem) }
            return .done
        default:
            return .failure("The runner cannot handle this command here.")
        }
    }

    func handleVersionCommand(_ command: RunnerCommand) -> RunnerReply {
        do {
            switch command {
            case .history(let id):
                return .history(id: id, versions: try catalog.history(id: id))
            case .diff(let id, let base, let target):
                return .diff(id: id, text: try catalog.diff(id: id, base: base, target: target))
            case .rollback(let id, let commit):
                let version = try catalog.rollback(id: id, toCommit: commit)
                reload()
                return .rolledBack(id: id, version: version)
            default:
                return .failure("The runner cannot handle this command here.")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func setEnabled(id: String, enabled: Bool) -> RunnerReply {
        guard manifests[id] != nil else { return .failure("\(id) is not installed.") }
        do {
            let warning = try catalog.setEnabled(id: id, enabled: enabled)
            reload()
            if let warning { logger.error("\(warning, privacy: .public)") }
            return .enabledChanged(id: id, enabled: enabled)
        } catch {
            return .failure("Could not \(enabled ? "enable" : "disable") \(id): \(error.localizedDescription)")
        }
    }

    // MARK: Index

    /// Opens `catalog.sqlite`, rebuilding it from the folders if it was missing or unreadable.
    func openIndex() {
        guard let opened = CatalogIndex.open(at: store.indexURL) else {
            logger.error("Could not open or create the catalog index at \(self.store.indexURL.path, privacy: .public)")
            return
        }
        index = opened.index
        if opened.needsRebuild, let problem = rebuildIndex() {
            logger.error("\(problem, privacy: .public)")
        }
    }

    /// Recreates the index from the automation folders and `runs.jsonl`. Returns a problem, or nil.
    @discardableResult
    func rebuildIndex() -> String? {
        guard let index else { return "The catalog index could not be opened." }
        do {
            try index.rebuild(from: catalog, registrationErrors: registrationErrors)
            logger.info("Rebuilt the catalog index")
            return nil
        } catch {
            return "Could not rebuild the catalog index: \(error.localizedDescription)"
        }
    }

    /// Brings the automations table in line with what is installed.
    func syncIndex() {
        guard let index else { return }
        do {
            try index.sync(catalog.indexRows(registrationErrors: registrationErrors))
        } catch {
            logger.error("Could not update the catalog index: \(error.localizedDescription, privacy: .public)")
        }
    }

    func indexRun(_ record: RunRecord) {
        do {
            try index?.insertRun(record)
        } catch {
            logger.error("Could not index a run: \(error.localizedDescription, privacy: .public)")
        }
    }

    func indexTestReport(_ report: TestReport, version: Int) {
        do {
            try index?.saveTestReport(report, version: version)
        } catch {
            logger.error("Could not index a test report: \(error.localizedDescription, privacy: .public)")
        }
    }
}
