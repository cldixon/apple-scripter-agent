import Foundation
@testable import Shared
import Testing

struct AgentCommandsTests {
    private func roundTrip<Message: Codable>(_ message: Message) throws -> Message {
        try XPCCoding.decode(Message.self, from: XPCCoding.encode(message))
    }

    @Test func agentCommandsRoundTrip() throws {
        let commands: [RunnerCommand] = [
            .searchReference(query: "text item delimiters", limit: 8),
            .readReference(id: "recipes/text-item-delimiters"),
            .introspectApp(app: "Finder", query: "window"),
            .introspectApp(app: "com.apple.mail", query: nil),
            .listApps,
            .listShortcuts,
            .checkPermissions([.accessibility, .automation("com.apple.finder"), .fullDiskAccess, .screenRecording]),
            .readAutomation(id: "insert-iso-date"),
            .writeDraft(
                manifest: Data(ExampleManifests.insertISODate.utf8),
                files: [DraftFile(path: "scripts/run.applescript", contents: "on run argv\nend run")]
            ),
            .validateDraft(id: "insert-iso-date"),
            .installDraft(id: "insert-iso-date"),
            .discardDraft(id: "insert-iso-date")
        ]
        for command in commands {
            #expect(try roundTrip(command) == command)
        }
    }

    @Test func agentRepliesRoundTrip() throws {
        let manifest = try AutomationManifest.decode(from: Data(ExampleManifests.insertISODate.utf8))
        let summary = AutomationSummary(manifest: manifest, issues: [], registrationError: nil, folderPath: "/tmp/x")
        let issue = ValidationIssue(.warning, "tests", "No tests declared.")
        let replies: [RunnerReply] = [
            .referenceHits([ReferenceHit(id: "a/b", title: "B", source: "Recipes", snippet: "**b** text")]),
            .referenceChunk(ReferenceChunk(id: "a/b", title: "B", source: "Recipes", text: "## B", truncated: true)),
            .appDictionary(AppDictionarySummary(
                app: "Finder", bundleID: "com.apple.finder", text: "#", truncated: false
            )),
            .apps([AppInfo(
                name: "Finder", bundleID: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app",
                scriptable: true, running: true
            )]),
            .shortcuts(["Make GIF", "Text Last Image"]),
            .permissions([
                PermissionStatus(permission: .accessibility, state: .granted, detail: "OK"),
                PermissionStatus(permission: .automation("com.apple.mail"), state: .unknown, detail: "Launch Mail")
            ]),
            .automation(AutomationDetail(summary: summary, manifestJSON: "{}", files: ["scripts/a.sh": "echo"])),
            .draftWritten(id: "insert-iso-date", issues: [issue]),
            .draftValidated(TestReport(
                automationID: "insert-iso-date", ranAt: Date(timeIntervalSince1970: 1_700_000_000),
                issues: [issue], results: [.init(name: "steps[0] compiles", passed: true, message: "OK")]
            ))
        ]
        for reply in replies {
            #expect(try roundTrip(reply) == reply)
        }
    }
}
