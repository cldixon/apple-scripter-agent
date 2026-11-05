import Foundation
@testable import Shared
import Testing

struct ScriptTestSandboxTests {
    @Test func quotingEscapesBackslashesAndQuotes() {
        #expect(ScriptTestSandbox.quoted("/tmp/plain") == #""/tmp/plain""#)
        #expect(ScriptTestSandbox.quoted(#"/tmp/say "hi""#) == #""/tmp/say \"hi\"""#)
        #expect(ScriptTestSandbox.quoted(#"/tmp/back\slash"#) == #""/tmp/back\\slash""#)
        #expect(ScriptTestSandbox.quoted("/tmp/line\nbreak") == #""/tmp/line\nbreak""#)
    }

    @Test func profileDeniesNetworkAppleEventsAndWrites() throws {
        let profile = ScriptTestSandbox.profile(writablePaths: ["/nonexistent/test-root"])
        let lines = profile.split(separator: "\n").map { String($0) }
        #expect(lines.first == "(version 1)")
        #expect(lines.contains("(allow default)"))
        #expect(lines.contains("(deny network*)"))
        #expect(lines.contains("(deny appleevent-send)"))
        #expect(lines.contains("(deny file-write*)"))
        #expect(profile.contains(#"(subpath "/nonexistent/test-root")"#))
        #expect(profile.contains(#"(literal "/dev/null")"#))
        // The allow comes after the deny: later rules win.
        let deny = try #require(profile.range(of: "(deny file-write*)"))
        let allow = try #require(profile.range(of: "(allow file-write*"))
        #expect(deny.lowerBound < allow.lowerBound)
        // Balanced parentheses.
        #expect(profile.filter { $0 == "(" }.count == profile.filter { $0 == ")" }.count)
    }

    @Test func profileEscapesAwkwardPaths() {
        let profile = ScriptTestSandbox.profile(writablePaths: [#"/nonexistent/a "quoted" \ path"#])
        #expect(profile.contains(#"(subpath "/nonexistent/a \"quoted\" \\ path")"#))
    }

    @Test func canonicalPathKeepsPrivate() throws {
        let temporary = FileManager.default.temporaryDirectory.path
        let canonical = ScriptTestSandbox.canonicalPath(temporary)
        #expect(!canonical.isEmpty)
        if temporary.hasPrefix("/var/") {
            #expect(canonical.hasPrefix("/private/var/"))
        }
        #expect(ScriptTestSandbox.canonicalPath("/nonexistent/x") == "/nonexistent/x")
    }

    @Test func argumentsChangeDirectoryThenExecTheTool() {
        let arguments = ScriptTestSandbox.arguments(
            profile: "(version 1)", directory: "/w", tool: "/bin/zsh", toolArguments: ["s.sh"]
        )
        #expect(arguments.prefix(2) == ["-p", "(version 1)"])
        #expect(arguments.suffix(4) == ["zsh", "/w", "/bin/zsh", "s.sh"])
        #expect(arguments.contains("-c"))
    }

    @Test func safeRelativePaths() {
        for path in ["a", "a/b.txt", "Archive/2024/x.pdf", ".hidden", "a/"] {
            #expect(ScriptTestPaths.isSafeRelative(path), "\(path)")
        }
        for path in ["", "/a", "~", "~/a", "..", "a/../b", "./a", "a\\b", "/"] {
            #expect(!ScriptTestPaths.isSafeRelative(path), "\(path)")
        }
    }

    @Test func toolInvocationFollowsTheInputContract() {
        let shell = ScriptTestPlanner.toolInvocation(.shell, scriptPath: "/s.sh", inputs: ["text": "hi"])
        #expect(shell.tool == "/bin/zsh")
        #expect(shell.arguments == ["/s.sh"])
        #expect(shell.environment["AUTOMATION_INPUT"] == #"{"text":"hi"}"#)
        #expect(shell.environment["AUTOMATION_VAR_text"] == "hi")

        let jxa = ScriptTestPlanner.toolInvocation(.jxa, scriptPath: "/s.js", inputs: ["text": "hi"])
        #expect(jxa.tool == "/usr/bin/osascript")
        #expect(jxa.arguments == ["-l", "JavaScript", "/s.js", #"{"text":"hi"}"#])
        #expect(jxa.environment.isEmpty)
    }

    @Test func plannerRefusesAppleEventsAndNonScriptSteps() throws {
        let workspace = try ScriptTestWorkspace.create(fixtures: nil, folder: nil)
        defer { workspace.remove() }
        let manifest = AutomationManifest(id: "x", name: "X", trigger: .manual, steps: [
            Step(.applescript(ScriptSource(source: "tell application \"Finder\" to activate"))),
            Step(.primitive(.readClipboard))
        ])
        #expect(throws: ScriptTestError.self) {
            try ScriptTestPlanner.command(
                .init(step: 0, expect: "x"), manifest: manifest, folder: nil, workspace: workspace
            )
        }
        #expect(throws: ScriptTestError.notAScriptStep(1)) {
            try ScriptTestPlanner.command(
                .init(step: 1, expect: "x"), manifest: manifest, folder: nil, workspace: workspace
            )
        }
    }

    @Test func plannerBuildsASandboxedCommand() throws {
        let workspace = try ScriptTestWorkspace.create(fixtures: nil, folder: nil)
        defer { workspace.remove() }
        let manifest = AutomationManifest(id: "x", name: "X", trigger: .manual, steps: [
            Step(.shell(ScriptSource(source: "echo hi")), timeout: 7)
        ])
        let command = try ScriptTestPlanner.command(
            .init(step: 0, inputs: ["text": "hi"], expect: "hi"), manifest: manifest, folder: nil, workspace: workspace
        )
        #expect(command.executable == "/usr/bin/sandbox-exec")
        #expect(command.timeout == 7)
        #expect(command.environment["HOME"] == workspace.work.path)
        #expect(command.environment["AUTOMATION_VAR_fixtures_dir"] == workspace.work.path)
        #expect(command.environment["AUTOMATION_VAR_text"] == "hi")
        #expect(command.arguments.contains(workspace.work.path))
        let profile = command.arguments.dropFirst().first ?? ""
        #expect(profile.contains("(subpath \(ScriptTestSandbox.quoted(workspace.root.path)))"))
    }

    @Test func workspaceCopiesFixtures() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "ScriptTestSandboxTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixtures = folder.appending(path: "tests/fixtures/inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        try "a".write(to: fixtures.appending(path: "a.txt"), atomically: true, encoding: .utf8)

        let workspace = try ScriptTestWorkspace.create(fixtures: "tests/fixtures/inbox", folder: folder)
        #expect(FileManager.default.fileExists(atPath: workspace.work.appending(path: "a.txt").path))
        #expect(FileManager.default.fileExists(atPath: workspace.temporary.path))
        workspace.remove()
        #expect(!FileManager.default.fileExists(atPath: workspace.root.path))

        #expect(throws: ScriptTestError.fixturesMissing("nope")) {
            try ScriptTestWorkspace.create(fixtures: "nope", folder: folder)
        }
        #expect(throws: ScriptTestError.unsafePath("../x")) {
            try ScriptTestWorkspace.create(fixtures: "../x", folder: folder)
        }
    }
}
