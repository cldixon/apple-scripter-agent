import Foundation
import Shared

/// Run Tests: static validation, compile checks, unit tests and harness tests, for an
/// installed automation or for a draft.
extension RunnerCore {
    func test(id: String) async -> TestReport? {
        guard let manifest = manifests[id] else { return nil }
        let report = await test(manifest, folder: store.folder(for: id), postsHotkeys: true)
        indexTestReport(report, version: manifest.version)
        return report
    }

    /// Tests `manifest` with its files in `folder`. Harness runs are logged with cause `test`.
    /// A draft's hotkey is not registered, so drafts pass `postsHotkeys: false` and their
    /// harness tests only call the automation directly.
    func test(_ manifest: AutomationManifest, folder: URL, postsHotkeys: Bool) async -> TestReport {
        let issues = ManifestValidator.validate(manifest, folder: folder)
        var results = await compileResults(manifest, folder: folder)
        results += await UnitTestRunner.run(manifest, folder: folder)
        for (position, test) in manifest.tests.enumerated() {
            guard case .harness(var harnessTest) = test else { continue }
            if !postsHotkeys { harnessTest.fire = .handler }
            results += await harness.run(harnessTest, name: "tests[\(position)] harness", manifest: manifest) {
                await self.run(manifest, folder: folder, cause: .test)
            }
        }
        return TestReport(automationID: manifest.id, ranAt: Date(), issues: issues, results: results)
    }

    /// Compiles every AppleScript/JXA step and syntax-checks every shell step.
    func compileResults(_ manifest: AutomationManifest, folder: URL?) async -> [TestReport.Result] {
        var results: [TestReport.Result] = []
        for (index, step) in manifest.steps.enumerated() {
            let language: ScriptLanguage
            let source: ScriptSource
            switch step.body {
            case .applescript(let script): (language, source) = (.applescript, script)
            case .jxa(let script): (language, source) = (.jxa, script)
            case .shell(let script): (language, source) = (.shell, script)
            default: continue
            }
            let name = "steps[\(index)] compiles"
            guard let text = ManifestValidator.scriptText(source, folder: folder) else {
                results.append(.init(name: name, passed: false, message: "The script could not be read."))
                continue
            }
            do {
                let errors = try await ScriptRunner.compile(language, source: text)
                results.append(.init(name: name, passed: errors.isEmpty, message: errors.isEmpty ? "OK" : errors))
            } catch {
                results.append(.init(name: name, passed: false, message: error.localizedDescription))
            }
        }
        return results
    }
}
