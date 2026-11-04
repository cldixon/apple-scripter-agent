import Foundation
@testable import Shared
import Testing

struct ManifestTests {
    private static let repoRoot = URL(filePath: #filePath)
        .deletingLastPathComponent() // SharedTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // Shared
        .deletingLastPathComponent() // repo root

    /// 2024-12-30T12:00:00Z
    private static let exampleClock = Date(timeIntervalSince1970: 1_735_560_000)

    private func dateExample() throws -> AutomationManifest {
        try AutomationManifest.decode(from: Data(ExampleManifests.insertISODate.utf8))
    }

    private func manifestData(trigger: String = #"{ "type": "manual" }"#, steps: String) -> Data {
        Data("""
        { "id": "sample", "trigger": \(trigger), "steps": [\(steps)] }
        """.utf8)
    }

    // MARK: Example manifest

    @Test func decodesDateExample() throws {
        let manifest = try dateExample()
        #expect(manifest.id == "insert-iso-date")
        #expect(manifest.name == "Insert today's date")
        #expect(manifest.trigger == .hotkey(Hotkey(key: "D", modifiers: [.ctrl, .opt, .cmd])))
        #expect(manifest.steps.count == 2)
        let first = try #require(manifest.steps.first)
        #expect(first.body == .primitive(.formatDate(pattern: "yyyy-MM-dd")))
        #expect(first.output == "date")
        #expect(manifest.steps[1].body == .primitive(.typeText("{{date}}")))
        #expect(manifest.steps[1].output == nil)
        #expect(manifest.permissions == [.accessibility])
        #expect(manifest.destructive == false)
        #expect(manifest.version == 1)
        #expect(manifest.tests.map(\.kindName) == ["unit", "unit", "harness"])
        #expect(manifest.tests.first == .unit(.init(step: 0, clock: Self.exampleClock, expect: "2024-12-30")))
        #expect(manifest.tests.last == .harness(.init(fire: .trigger, expectText: "{{today:yyyy-MM-dd}}")))
    }

    @Test func roundTripsThroughEncoding() throws {
        let manifest = try dateExample()
        let decoded = try AutomationManifest.decode(from: manifest.encoded())
        #expect(decoded == manifest)
    }

    @Test func roundTripsEveryStepType() throws {
        let manifest = AutomationManifest(
            id: "every-step",
            name: "Every step",
            trigger: .manual,
            steps: [
                Step(.primitive(.readClipboard), output: "clip", timeout: 2.5),
                Step(.primitive(.pasteText("{{clip}}"))),
                Step(.primitive(.writeClipboard("x"))),
                Step(.primitive(.notify(title: "Hi", text: "there"))),
                Step(.primitive(.notify(title: nil, text: "untitled"))),
                Step(.primitive(.openURL("https://example.com"))),
                Step(.primitive(.launchApp("com.apple.TextEdit"))),
                Step(.primitive(.delay(seconds: 0.5))),
                Step(.applescript(ScriptSource(file: "scripts/a.applescript"))),
                Step(.jxa(ScriptSource(source: "1 + 1"))),
                Step(.shell(ScriptSource(source: "echo hi"))),
                Step(.shortcut(name: "Do it", input: "{{clip}}")),
                Step(.accessibility(action: "press"))
            ],
            permissions: [.accessibility, .automation("com.apple.finder")],
            destructive: true,
            tests: [.unit(.init(step: 0, clipboard: "seed", expect: "seed"))],
            version: 3
        )
        let decoded = try AutomationManifest.decode(from: manifest.encoded())
        #expect(decoded == manifest)
    }

    @Test func appliesDefaults() throws {
        let data = manifestData(steps: #"{ "type": "primitive", "action": "readClipboard" }"#)
        let manifest = try AutomationManifest.decode(from: data)
        #expect(manifest.id == "sample")
        #expect(manifest.name == "sample")
        #expect(manifest.trigger == .manual)
        #expect(manifest.steps == [Step(.primitive(.readClipboard))])
        #expect(manifest.permissions.isEmpty)
        #expect(manifest.destructive == false)
        #expect(manifest.tests.isEmpty)
        #expect(manifest.version == 1)
        #expect(manifest.steps.first?.effectiveTimeout == Step.defaultTimeout)
    }

    // MARK: Repository examples

    @Test func decodesRepositoryDateExample() throws {
        let url = Self.repoRoot.appending(path: "Examples/insert-iso-date/manifest.json")
        let manifest = try AutomationManifest.decode(from: Data(contentsOf: url))
        let expected = try dateExample()
        #expect(manifest == expected)
    }

    @Test func decodesRepositoryFinderExample() throws {
        let url = Self.repoRoot.appending(path: "Examples/copy-finder-paths/manifest.json")
        let manifest = try AutomationManifest.decode(from: Data(contentsOf: url))
        #expect(manifest.id == "copy-finder-paths")
        let first = try #require(manifest.steps.first)
        #expect(first.body == .applescript(ScriptSource(file: "scripts/selected-paths.applescript")))
        #expect(first.output == "paths")
        #expect(manifest.permissions == [.automation("com.apple.finder")])
    }

    // MARK: Decoding failures

    @Test func unknownTriggerTypeThrows() {
        let data = manifestData(
            trigger: #"{ "type": "timer" }"#,
            steps: #"{ "type": "primitive", "action": "readClipboard" }"#
        )
        #expect(throws: DecodingError.self) { try AutomationManifest.decode(from: data) }
    }

    @Test func unknownStepTypeThrows() {
        let data = manifestData(steps: #"{ "type": "python", "source": "print(1)" }"#)
        #expect(throws: DecodingError.self) { try AutomationManifest.decode(from: data) }
    }

    @Test func unknownPrimitiveActionThrows() {
        let data = manifestData(steps: #"{ "type": "primitive", "action": "explode" }"#)
        #expect(throws: DecodingError.self) { try AutomationManifest.decode(from: data) }
    }

    @Test func scriptStepWithoutFileOrSourceThrows() {
        let data = manifestData(steps: #"{ "type": "applescript" }"#)
        #expect(throws: DecodingError.self) { try AutomationManifest.decode(from: data) }
    }

    @Test func missingStepsThrows() {
        let data = Data(#"{ "id": "sample", "trigger": { "type": "manual" } }"#.utf8)
        #expect(throws: DecodingError.self) { try AutomationManifest.decode(from: data) }
    }

    // MARK: Hotkeys and permissions

    @Test func hotkeyDisplayStringIgnoresModifierOrder() {
        #expect(Hotkey(key: "D", modifiers: [.ctrl, .opt, .cmd]).displayString == "⌃⌥⌘D")
        #expect(Hotkey(key: "D", modifiers: [.cmd, .ctrl, .opt]).displayString == "⌃⌥⌘D")
        #expect(Hotkey(key: "d", modifiers: [.opt, .cmd, .ctrl, .cmd]).displayString == "⌃⌥⌘D")
        #expect(Hotkey(key: "k", modifiers: [.cmd, .shift]).displayString == "⇧⌘K")
    }

    @Test func triggerSummary() {
        #expect(Trigger.manual.summary == "Manual")
        #expect(Trigger.hotkey(Hotkey(key: "D", modifiers: [.cmd])).summary == "Hotkey ⌘D")
    }

    @Test func automationPermissionTarget() {
        #expect(Permission.automation("com.apple.finder").automationTarget == "com.apple.finder")
        #expect(Permission.automation("com.apple.finder").rawValue == "automation:com.apple.finder")
        #expect(Permission.accessibility.automationTarget == nil)
    }

    // MARK: Unit tests

    @Test func unitTestClockParses() throws {
        let data = Data(#"{ "kind": "unit", "step": 0, "clock": "2024-12-30T12:00:00Z", "expect": "x" }"#.utf8)
        let test = try JSONDecoder().decode(ManifestTest.self, from: data)
        guard case .unit(let unit) = test else {
            Issue.record("Expected a unit test, got \(test)")
            return
        }
        #expect(unit.clock == Self.exampleClock)
        #expect(unit.step == 0)
        #expect(unit.expect == "x")
        #expect(unit.clipboard == nil)
    }

    @Test func badUnitTestClockThrows() {
        let data = Data(#"{ "kind": "unit", "step": 0, "clock": "yesterday", "expect": "x" }"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ManifestTest.self, from: data) }
    }

    @Test func unknownTestKindThrows() {
        let data = Data(#"{ "kind": "fuzz" }"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ManifestTest.self, from: data) }
    }

    @Test func harnessFireDefaultsToTrigger() throws {
        let data = Data(#"{ "kind": "harness", "expectText": "hi" }"#.utf8)
        let test = try JSONDecoder().decode(ManifestTest.self, from: data)
        #expect(test == .harness(.init(fire: .trigger, expectText: "hi")))
    }
}
