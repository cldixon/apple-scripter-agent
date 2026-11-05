import Foundation
@testable import Shared
import Testing

/// Really runs scripts under `sandbox-exec` with the profile and command line the runner uses.
@Suite(.enabled(if: ScriptTestSandbox.isAvailable))
struct ScriptTestSandboxIntegrationTests {
    private func launch(_ command: ScriptTestCommand) throws -> ScriptResult {
        let process = Process()
        process.executableURL = URL(filePath: command.executable)
        process.arguments = command.arguments
        var environment = ProcessInfo.processInfo.environment
        environment.merge(command.environment) { _, new in new }
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var text = String(bytes: outputData, encoding: .utf8) ?? ""
        if text.hasSuffix("\n") { text.removeLast() }
        return ScriptResult(
            output: text,
            errorOutput: String(bytes: errorData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus,
            duration: 0,
            timedOut: false
        )
    }

    private func manifest(_ step: Step) -> AutomationManifest {
        AutomationManifest(id: "sandbox-test", name: "Sandbox test", trigger: .manual, steps: [step])
    }

    @Test func writesInsideTheWorkspaceOnly() throws {
        let workspace = try ScriptTestWorkspace.create(fixtures: nil, folder: nil)
        defer { workspace.remove() }
        let outside = FileManager.default.temporaryDirectory
            .appending(path: "ScriptTestOutside-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }

        let source = """
            print -r -- inside > inside.txt || exit 3
            print -r -- quiet > /dev/null || exit 4
            print -r -- temp > "$TMPDIR/scratch.txt" || exit 5
            if print -r -- nope > "$AUTOMATION_VAR_outside" 2>/dev/null; then print escaped; else print blocked; fi
            """
        let test = ManifestTest.ScriptTest(step: 0, inputs: ["outside": outside.path], expect: "blocked")
        let command = try ScriptTestPlanner.command(
            test, manifest: manifest(Step(.shell(ScriptSource(source: source)))), folder: nil, workspace: workspace
        )
        let result = try launch(command)

        #expect(result.exitCode == 0, "\(result.errorOutput)")
        #expect(result.output == "blocked")
        #expect(FileManager.default.fileExists(atPath: workspace.work.appending(path: "inside.txt").path))
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func archivesFixtureFiles() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "ScriptTestAutomation-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let inbox = folder.appending(path: "tests/fixtures/downloads/inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        for name in ["a.pdf", "b.pdf", "keep.txt"] {
            try name.write(to: inbox.appending(path: name), atomically: true, encoding: .utf8)
        }

        let source = """
            mkdir -p Archive && mv inbox/*.pdf Archive/ && ls Archive | wc -l | tr -d ' '
            """
        let test = ManifestTest.ScriptTest(
            step: 0,
            fixtures: "tests/fixtures/downloads",
            expect: "2",
            expectFiles: ["Archive/a.pdf", "Archive/b.pdf", "inbox/keep.txt"],
            expectMissing: ["inbox/a.pdf"]
        )
        let workspace = try ScriptTestWorkspace.create(fixtures: test.fixtures, folder: folder)
        defer { workspace.remove() }
        let command = try ScriptTestPlanner.command(
            test, manifest: manifest(Step(.shell(ScriptSource(source: source)))), folder: folder, workspace: workspace
        )
        let outcome = try launch(command)
        let result = ScriptTestEvaluator.result(
            name: "tests[0] script, step 0", test: test, outcome: outcome, workDirectory: workspace.work
        )
        #expect(result.passed, "\(result.message)")
        // The original fixtures are untouched.
        #expect(FileManager.default.fileExists(atPath: inbox.appending(path: "a.pdf").path))
    }

    @Test func appleScriptReceivesInputs() throws {
        let workspace = try ScriptTestWorkspace.create(fixtures: nil, folder: nil)
        defer { workspace.remove() }
        let source = """
            on run argv
                return "got " & (item 1 of argv)
            end run
            """
        let test = ManifestTest.ScriptTest(step: 0, inputs: ["text": "hello"], expectContains: #""text":"hello""#)
        let command = try ScriptTestPlanner.command(
            test,
            manifest: manifest(Step(.applescript(ScriptSource(source: source)), timeout: 30)),
            folder: nil,
            workspace: workspace
        )
        let outcome = try launch(command)
        let result = ScriptTestEvaluator.result(
            name: "applescript", test: test, outcome: outcome, workDirectory: workspace.work
        )
        #expect(result.passed, "\(result.message)")
    }
}
