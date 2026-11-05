import Foundation

/// Checks a script test's outcome: the script's exit, its output, and the files left in the
/// fixture copy.
public enum ScriptTestEvaluator {
    /// The report line for one script test run.
    public static func result(
        name: String,
        test: ManifestTest.ScriptTest,
        outcome: ScriptResult,
        workDirectory: URL,
        now: Date = Date()
    ) -> TestReport.Result {
        if outcome.timedOut {
            return .init(name: name, passed: false, message: "The script did not finish in time.")
        }
        guard outcome.exitCode == 0 else {
            return .init(name: name, passed: false, message: failureMessage(outcome))
        }
        let failures = check(test, output: outcome.output, workDirectory: workDirectory, now: now)
        if failures.isEmpty {
            return .init(name: name, passed: true, message: "Got \"\(outcome.output)\"")
        }
        return .init(name: name, passed: false, message: failures.joined(separator: "\n"))
    }

    /// Every expectation `test` does not meet, as messages; empty when it passes.
    public static func check(
        _ test: ManifestTest.ScriptTest,
        output: String,
        workDirectory: URL,
        now: Date = Date()
    ) -> [String] {
        var failures: [String] = []
        if let expect = test.expect {
            do {
                let expected = try Template.render(expect, variables: [:], now: now)
                if output != expected { failures.append("Expected \"\(expected)\", got \"\(output)\"") }
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if let fragment = test.expectContains, !output.contains(fragment) {
            failures.append("Expected the output to contain \"\(fragment)\", got \"\(output)\"")
        }
        for path in test.expectFiles {
            if !ScriptTestPaths.isSafeRelative(path) {
                failures.append("\"\(path)\" is not a relative path inside the fixtures.")
            } else if !exists(path, in: workDirectory) {
                failures.append("Expected \(path) to exist; it does not.\(listing(workDirectory))")
            }
        }
        for path in test.expectMissing {
            if !ScriptTestPaths.isSafeRelative(path) {
                failures.append("\"\(path)\" is not a relative path inside the fixtures.")
            } else if exists(path, in: workDirectory) {
                failures.append("Expected \(path) to be gone; it still exists.")
            }
        }
        return failures
    }

    private static func exists(_ path: String, in directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: path).path)
    }

    /// Up to 40 paths in the fixture copy, to help the agent see what the script did.
    static func listing(_ directory: URL) -> String {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else { return "" }
        var paths: [String] = []
        while let path = enumerator.nextObject() as? String, paths.count < 40 {
            paths.append(path)
        }
        if paths.isEmpty { return " The fixture folder is empty." }
        return " The fixture folder has: " + paths.sorted().joined(separator: ", ")
    }

    static func failureMessage(_ outcome: ScriptResult) -> String {
        let text = outcome.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = text.isEmpty ? "The script exited with status \(outcome.exitCode)." : text
        let lowercased = message.lowercased()
        let sandboxSigns = ["operation not permitted", "deny", "-1743", "-10004", "sandbox"]
        if sandboxSigns.contains(where: { lowercased.contains($0) }) {
            message += "\nScript tests run in a sandbox: no network, no Apple Events, and files can only "
                + "be written inside the fixture copy (the working directory, $HOME and fixtures_dir)."
        }
        return message
    }
}
