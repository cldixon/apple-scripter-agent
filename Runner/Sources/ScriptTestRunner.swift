import Foundation
import Shared

/// Runs a manifest's `script` tests: each one runs a single script step for real under
/// `sandbox-exec` (no network, no Apple Events, writes only in its temporary folder), in a
/// fresh copy of its fixtures, then checks the output and the files left behind.
enum ScriptTestRunner {
    static func run(_ manifest: AutomationManifest, folder: URL?) async -> [TestReport.Result] {
        var results: [TestReport.Result] = []
        for (index, test) in manifest.tests.enumerated() {
            guard case .script(let scriptTest) = test else { continue }
            let name = "tests[\(index)] script, step \(scriptTest.step)"
            results.append(await run(scriptTest, name: name, manifest: manifest, folder: folder))
        }
        return results
    }

    private static func run(
        _ test: ManifestTest.ScriptTest,
        name: String,
        manifest: AutomationManifest,
        folder: URL?
    ) async -> TestReport.Result {
        guard ScriptTestSandbox.isAvailable else {
            return .init(name: name, passed: false, message: "sandbox-exec is missing, so script tests cannot run.")
        }
        let workspace: ScriptTestWorkspace
        do {
            workspace = try ScriptTestWorkspace.create(fixtures: test.fixtures, folder: folder)
        } catch {
            return .init(name: name, passed: false, message: error.localizedDescription)
        }
        defer { workspace.remove() }
        do {
            let command = try ScriptTestPlanner.command(test, manifest: manifest, folder: folder, workspace: workspace)
            let outcome = try await ScriptRunner.runTool(
                command.executable,
                arguments: command.arguments,
                environment: command.environment,
                timeout: command.timeout
            )
            return ScriptTestEvaluator.result(
                name: name, test: test, outcome: outcome, workDirectory: workspace.work
            )
        } catch {
            return .init(name: name, passed: false, message: error.localizedDescription)
        }
    }
}
