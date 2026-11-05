import Foundation
@testable import Shared
import Testing

/// Sweep 2: the copySelection, pressKeys and askText primitives, key combinations,
/// default timeouts and their static checks.
struct RuntimePrimitivesTests {
    private func step(_ json: String) throws -> Step {
        try JSONDecoder().decode(Step.self, from: Data(json.utf8))
    }

    private func roundTrip(_ step: Step) throws -> Step {
        try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step))
    }

    private func encodedKeys(_ step: Step) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(step))
        let dictionary = try #require(object as? [String: Any])
        return Set(dictionary.keys)
    }

    // MARK: Coding

    @Test func decodesCopySelection() throws {
        let decoded = try step(#"{ "type": "primitive", "action": "copySelection", "as": "selection" }"#)
        #expect(decoded == Step(.primitive(.copySelection), output: "selection"))
        #expect(try roundTrip(decoded) == decoded)
        #expect(try encodedKeys(decoded) == ["type", "action", "as"])
    }

    @Test func decodesPressKeys() throws {
        let decoded = try step(#"{ "type": "primitive", "action": "pressKeys", "keys": "cmd+shift+4" }"#)
        #expect(decoded == Step(.primitive(.pressKeys("cmd+shift+4"))))
        #expect(try roundTrip(decoded) == decoded)
        #expect(try encodedKeys(decoded) == ["type", "action", "keys"])
    }

    @Test func pressKeysNeedsKeys() {
        #expect(throws: DecodingError.self) {
            _ = try step(#"{ "type": "primitive", "action": "pressKeys" }"#)
        }
    }

    @Test func decodesAskText() throws {
        let json = #"{ "type": "primitive", "action": "askText", "prompt": "Name?", "default": "x", "as": "name" }"#
        let decoded = try step(json)
        #expect(decoded == Step(.primitive(.askText(prompt: "Name?", defaultValue: "x")), output: "name"))
        #expect(try roundTrip(decoded) == decoded)
        #expect(try encodedKeys(decoded) == ["type", "action", "prompt", "default", "as"])

        let withoutDefault = try step(#"{ "type": "primitive", "action": "askText", "prompt": "Name?" }"#)
        #expect(withoutDefault == Step(.primitive(.askText(prompt: "Name?", defaultValue: nil))))
        #expect(try encodedKeys(withoutDefault) == ["type", "action", "prompt"])
    }

    @Test func askTextNeedsPrompt() {
        #expect(throws: DecodingError.self) {
            _ = try step(#"{ "type": "primitive", "action": "askText" }"#)
        }
    }

    @Test func newActionNamesAreListed() {
        let primitives: [Primitive] = [
            .copySelection, .pressKeys("cmd+c"), .askText(prompt: "Name?", defaultValue: nil)
        ]
        for primitive in primitives {
            #expect(Primitive.actionNames.contains(primitive.actionName))
        }
        #expect(Primitive.copySelection.requiredPermissions == [.accessibility])
        #expect(Primitive.pressKeys("cmd+c").requiredPermissions == [.accessibility])
        #expect(Primitive.askText(prompt: "Name?", defaultValue: nil).requiredPermissions.isEmpty)
        #expect(Primitive.askText(prompt: "{{a}}", defaultValue: "{{b}}").templateStrings == ["{{a}}", "{{b}}"])
    }

    // MARK: Key combinations

    @Test func parsesKeyCombos() throws {
        let screenshot = try KeyCombo.parse("cmd+shift+4")
        #expect(screenshot.modifiers == [.cmd, .shift])
        #expect(screenshot.key == "4")
        #expect(screenshot.keyCode == 0x15)
        #expect(screenshot.description == "cmd+shift+4")

        let spaced = try KeyCombo.parse(" Control + Option + Space ")
        #expect(spaced.modifiers == [.ctrl, .opt])
        #expect(spaced.keyCode == 0x31)
        #expect(spaced.description == "ctrl+opt+space")

        let plain = try KeyCombo.parse("return")
        #expect(plain.modifiers.isEmpty)
        #expect(plain.keyCode == 0x24)

        #expect(try KeyCombo.parse("cmd+cmd+a").modifiers == [.cmd])
        #expect(try KeyCombo.parse("alt+left").modifiers == [.opt])
        #expect(try KeyCombo.parse("cmd+-").keyCode == 0x1B)
        #expect(try KeyCombo.parse("pageDown").keyCode == 0x79)
    }

    @Test func rejectsBadKeyCombos() {
        #expect(throws: KeyCombo.ParseError.unknownKey("hyper")) { try KeyCombo.parse("cmd+hyper") }
        #expect(throws: KeyCombo.ParseError.noKey("cmd+shift")) { try KeyCombo.parse("cmd+shift") }
        #expect(throws: KeyCombo.ParseError.noKey("")) { try KeyCombo.parse("") }
        #expect(throws: KeyCombo.ParseError.severalKeys("cmd+a+b")) { try KeyCombo.parse("cmd+a+b") }
    }

    // MARK: Timeouts

    @Test func defaultTimeoutsDependOnStepType() throws {
        #expect(Step(.primitive(.readClipboard)).effectiveTimeout == 10)
        #expect(Step(.primitive(.copySelection)).effectiveTimeout == 10)
        #expect(Step(.primitive(.askText(prompt: "Name?", defaultValue: nil))).effectiveTimeout == 300)
        #expect(Step(.applescript(ScriptSource(source: "1"))).effectiveTimeout == 30)
        #expect(Step(.jxa(ScriptSource(source: "1"))).effectiveTimeout == 30)
        #expect(Step(.shell(ScriptSource(source: "true"))).effectiveTimeout == 30)
        #expect(Step(.shortcut(name: "Make PDF", input: nil)).effectiveTimeout == 60)
        #expect(Step(.shell(ScriptSource(source: "true")), timeout: 5).effectiveTimeout == 5)
        #expect(Step.defaultTimeout(for: .primitive(.delay(seconds: 1))) == Step.defaultTimeout)

        let decoded = try step(#"{ "type": "primitive", "action": "askText", "prompt": "Name?" }"#)
        #expect(decoded.timeout == nil)
        #expect(decoded.effectiveTimeout == 300)
    }

    // MARK: Validation

    private func validationErrors(_ steps: [Step], permissions: [Permission] = []) -> [ValidationIssue] {
        let manifest = AutomationManifest(
            id: "sample", name: "Sample", trigger: .manual, steps: steps, permissions: permissions,
            tests: [.unit(.init(step: 0, expect: "anything"))]
        )
        return ManifestValidator.validate(manifest).filter { $0.severity == .error }
    }

    @Test func validPrimitivesHaveNoErrors() {
        let errors = validationErrors([
            Step(.primitive(.copySelection), output: "selection"),
            Step(.primitive(.askText(prompt: "Replace {{selection}} with?", defaultValue: "{{selection}}"))),
            Step(.primitive(.pressKeys("cmd+shift+4")))
        ], permissions: [.accessibility])
        #expect(errors.isEmpty, "\(errors)")
    }

    @Test func selectionAndKeysNeedAccessibility() {
        let errors = validationErrors([
            Step(.primitive(.copySelection)),
            Step(.primitive(.pressKeys("cmd+c")))
        ])
        #expect(errors.map { $0.location } == ["steps[0]", "steps[1]"])
        #expect(errors.allSatisfy { $0.message.contains("accessibility") })
    }

    @Test func badKeysAreAnError() {
        let errors = validationErrors([Step(.primitive(.pressKeys("cmd+hyper")))], permissions: [.accessibility])
        #expect(errors.map { $0.location } == ["steps[0]"])
        #expect(errors.first?.message.contains("hyper") == true)

        let noKey = validationErrors([Step(.primitive(.pressKeys("cmd+shift")))], permissions: [.accessibility])
        #expect(noKey.map { $0.location } == ["steps[0]"])
    }

    @Test func askTextNeedsAPrompt() {
        let errors = validationErrors([Step(.primitive(.askText(prompt: "  ", defaultValue: nil)))])
        #expect(errors.map { $0.location } == ["steps[0]"])
        #expect(errors.first?.message.contains("prompt") == true)
    }

    @Test func askTextPromptReferencesAreChecked() {
        let errors = validationErrors([Step(.primitive(.askText(prompt: "{{missing}}?", defaultValue: nil)))])
        #expect(errors.first?.message.contains("{{missing}}") == true)
    }
}
