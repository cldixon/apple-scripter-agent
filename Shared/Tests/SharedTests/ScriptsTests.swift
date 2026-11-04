import Foundation
@testable import Shared
import Testing

struct ScriptsTests {
    @Test func findsAppleScriptTargets() {
        let source = """
        tell application "Finder"
            set x to selection
        end tell
        tell application id "com.apple.mail" to get name
        TELL APPLICATION "Finder" to activate
        """
        #expect(ScriptAnalysis.targetApplications(in: source, language: .applescript) == ["Finder", "com.apple.mail"])
    }

    @Test func findsJXATargets() {
        let source = "const finder = Application('Finder'); const mail = Application(\"Mail\");"
        #expect(ScriptAnalysis.targetApplications(in: source, language: .jxa) == ["Finder", "Mail"])
    }

    @Test func shellHasNoTargets() {
        #expect(ScriptAnalysis.targetApplications(in: "osascript -e 'tell application \"Finder\"'", language: .shell)
            .isEmpty)
    }

    @Test func inputJSONIsSortedObject() {
        let request = ScriptRequest(language: .shell, variables: ["b": "2", "a": "one \"quoted\""])
        #expect(request.inputJSON == #"{"a":"one \"quoted\"","b":"2"}"#)
        #expect(ScriptRequest(language: .shell).inputJSON == "{}")
    }

    @Test func osaLanguageNames() {
        #expect(ScriptLanguage.applescript.osaLanguage == "AppleScript")
        #expect(ScriptLanguage.jxa.osaLanguage == "JavaScript")
        #expect(ScriptLanguage.shell.osaLanguage == nil)
    }

    @Test func scriptResultSucceeded() {
        #expect(ScriptResult(output: "", errorOutput: "", exitCode: 0, duration: 0.1, timedOut: false).succeeded)
        #expect(!ScriptResult(output: "", errorOutput: "x", exitCode: 1, duration: 0.1, timedOut: false).succeeded)
        #expect(!ScriptResult(output: "", errorOutput: "", exitCode: 0, duration: 3, timedOut: true).succeeded)
    }

    @Test func snippetCommandsRoundTrip() throws {
        let commands: [RunnerCommand] = [
            .runSnippet(language: .applescript, source: "return 1", timeout: 5),
            .compile(language: .jxa, source: "1")
        ]
        for command in commands {
            #expect(try XPCCoding.decode(RunnerCommand.self, from: XPCCoding.encode(command)) == command)
        }
        let reply = RunnerReply.snippet(ScriptResult(output: "1", errorOutput: "", exitCode: 0, duration: 0.2,
                                                     timedOut: false))
        #expect(try XPCCoding.decode(RunnerReply.self, from: XPCCoding.encode(reply)) == reply)
    }

    @Test func repoExamplesValidateWithTheirFolders() throws {
        let examples = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Examples")
        for name in ["insert-iso-date", "copy-finder-paths", "word-count-clipboard"] {
            let folder = examples.appending(path: name)
            let data = try Data(contentsOf: folder.appending(path: "manifest.json"))
            let manifest = try AutomationManifest.decode(from: data)
            let issues = ManifestValidator.validate(manifest, folder: folder)
            #expect(!ManifestValidator.hasErrors(issues), "\(name): \(issues)")
        }
    }
}
