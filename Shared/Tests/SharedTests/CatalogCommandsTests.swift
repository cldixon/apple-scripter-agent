import Foundation
@testable import Shared
import Testing

struct CatalogCommandsTests {
    private static let sampleManifest = AutomationManifest(
        id: "sample",
        name: "Sample",
        trigger: .hotkey(Hotkey(key: "D", modifiers: [.ctrl, .cmd])),
        steps: [Step(.primitive(.readClipboard), output: "clip")],
        tests: [.unit(.init(step: 0, expect: ""))]
    )

    private func roundTrip<Message: Codable>(_ message: Message) throws -> Message {
        try XPCCoding.decode(Message.self, from: XPCCoding.encode(message))
    }

    @Test func catalogCommandsRoundTrip() throws {
        let hash = String(repeating: "a", count: 40)
        let commands: [RunnerCommand] = [
            .setEnabled(id: "sample", enabled: false),
            .setEnabled(id: "sample", enabled: true),
            .history(id: "sample"),
            .diff(id: "sample", base: nil, target: hash),
            .diff(id: "sample", base: "0123abcd", target: hash),
            .rollback(id: "sample", toCommit: hash),
            .rebuildIndex
        ]
        for command in commands {
            #expect(try roundTrip(command) == command)
        }
    }

    @Test func catalogRepliesRoundTrip() throws {
        let versions = [
            AutomationVersion(
                id: String(repeating: "b", count: 40),
                date: Date(timeIntervalSince1970: 1_700_000_100),
                message: "Replace sample v2",
                version: 2
            ),
            AutomationVersion(
                id: String(repeating: "c", count: 40),
                date: Date(timeIntervalSince1970: 1_700_000_000),
                message: "Remove sample",
                version: nil
            )
        ]
        let disabled = AutomationSummary(
            manifest: Self.sampleManifest, issues: [], registrationError: nil, folderPath: "/tmp/sample",
            enabled: false
        )
        let replies: [RunnerReply] = [
            .enabledChanged(id: "sample", enabled: false),
            .history(id: "sample", versions: versions),
            .history(id: "sample", versions: []),
            .diff(id: "sample", text: "diff --git a/sample/manifest.json b/sample/manifest.json\n+ \"version\" : 2"),
            .rolledBack(id: "sample", version: 1),
            .automations([disabled], paused: false)
        ]
        for reply in replies {
            #expect(try roundTrip(reply) == reply)
        }
        #expect(versions[0].shortHash == "bbbbbbb")
    }

    @Test func summaryStatus() {
        let active = AutomationSummary(
            manifest: Self.sampleManifest, issues: [], registrationError: nil, folderPath: "/tmp/sample"
        )
        #expect(active.status == .active)
        #expect(active.isEnabled)

        let disabled = AutomationSummary(
            manifest: Self.sampleManifest, issues: [], registrationError: nil, folderPath: "/tmp/sample",
            enabled: false
        )
        #expect(disabled.status == .disabled)
        #expect(!disabled.isActive)
        #expect(!disabled.isEnabled)

        let broken = AutomationSummary(
            manifest: Self.sampleManifest, issues: [], registrationError: "Hotkey taken", folderPath: "/tmp/sample"
        )
        #expect(broken.status == .broken)

        let awaiting = AutomationSummary(
            manifest: Self.sampleManifest, issues: [], registrationError: nil, folderPath: "/tmp/sample",
            status: .awaitingApproval
        )
        #expect(awaiting.status == .awaitingApproval)
        #expect(!awaiting.isActive)
    }

    @Test func statusRawValuesMatchTheIndex() {
        let raw = AutomationStatus.allCases.map { $0.rawValue }
        #expect(raw == ["draft", "validating", "awaiting_approval", "active", "disabled", "broken"])
    }
}
