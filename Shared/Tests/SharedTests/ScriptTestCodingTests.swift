import Foundation
@testable import Shared
import Testing

struct ScriptTestCodingTests {
    private func decode(_ json: String) throws -> ManifestTest {
        try JSONDecoder().decode(ManifestTest.self, from: Data(json.utf8))
    }

    private func roundTrip(_ test: ManifestTest) throws -> ManifestTest {
        let data = try JSONEncoder().encode(test)
        return try JSONDecoder().decode(ManifestTest.self, from: data)
    }

    private func keys(_ test: ManifestTest) throws -> Set<String> {
        let data = try JSONEncoder().encode(test)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(object.keys)
    }

    @Test func scriptTestDecodesEveryField() throws {
        let test = try decode(#"""
            {
              "kind": "script", "step": 1, "inputs": { "text": "Hello" },
              "fixtures": "tests/fixtures/downloads", "expect": "moved 2",
              "expectContains": "moved", "expectFiles": ["Archive/a.pdf"], "expectMissing": ["a.pdf"]
            }
            """#)
        let expected = ManifestTest.script(.init(
            step: 1,
            inputs: ["text": "Hello"],
            fixtures: "tests/fixtures/downloads",
            expect: "moved 2",
            expectContains: "moved",
            expectFiles: ["Archive/a.pdf"],
            expectMissing: ["a.pdf"]
        ))
        #expect(test == expected)
        #expect(test.kindName == "script")
    }

    @Test func scriptTestDefaults() throws {
        let test = try decode(#"{ "kind": "script", "step": 0, "expectContains": "x" }"#)
        guard case .script(let script) = test else {
            Issue.record("Expected a script test, got \(test)")
            return
        }
        #expect(script.inputs.isEmpty)
        #expect(script.fixtures == nil)
        #expect(script.expect == nil)
        #expect(script.expectFiles.isEmpty)
        #expect(script.expectMissing.isEmpty)
        #expect(script.hasExpectation)
    }

    @Test func scriptTestRoundTrips() throws {
        let full = ManifestTest.script(.init(
            step: 2,
            inputs: ["name": "value", "other": "two"],
            fixtures: "fixtures",
            expect: "{{today:yyyy}}",
            expectContains: "20",
            expectFiles: ["a", "b/c"],
            expectMissing: ["d"]
        ))
        #expect(try roundTrip(full) == full)
        let minimal = ManifestTest.script(.init(step: 0, expect: "x"))
        #expect(try roundTrip(minimal) == minimal)
        #expect(try keys(minimal) == ["kind", "step", "expect"])
    }

    @Test func scriptTestWithoutExpectationHasNone() throws {
        let test = ManifestTest.ScriptTest(step: 0)
        #expect(!test.hasExpectation)
        #expect(ManifestTest.ScriptTest(step: 0, expectMissing: ["x"]).hasExpectation)
    }

    @Test func harnessSetupTextAndSelectDecode() throws {
        let test = try decode(#"{ "kind": "harness", "setupText": "hello", "select": "all", "expectText": "HELLO" }"#)
        #expect(test == .harness(.init(fire: .trigger, setupText: "hello", select: .all, expectText: "HELLO")))
        let none = try decode(#"{ "kind": "harness", "setupText": "x", "select": "none", "expectText": "y" }"#)
        #expect(none == .harness(.init(setupText: "x", select: .atEnd, expectText: "y")))
    }

    @Test func harnessSelectDefaultsToNone() throws {
        let test = try decode(#"{ "kind": "harness", "expectText": "hi" }"#)
        guard case .harness(let harness) = test else {
            Issue.record("Expected a harness test, got \(test)")
            return
        }
        #expect(harness.select == .atEnd)
        #expect(harness.setupText == nil)
    }

    @Test func badSelectThrows() {
        #expect(throws: DecodingError.self) {
            try decode(#"{ "kind": "harness", "select": "some", "expectText": "x" }"#)
        }
    }

    @Test func harnessRoundTrips() throws {
        let selected = ManifestTest.harness(.init(fire: .handler, setupText: "abc", select: .all, expectText: "ABC"))
        #expect(try roundTrip(selected) == selected)
        let plain = ManifestTest.harness(.init(expectText: "x"))
        #expect(try roundTrip(plain) == plain)
        #expect(try keys(plain) == ["kind", "fire", "expectText"])
    }

    @Test func schemaListsEveryTestKind() throws {
        let object = try JSONSerialization.jsonObject(with: Data(ManifestSchema.json.utf8))
        let root = try #require(object as? [String: Any])
        let defs = try #require(root["$defs"] as? [String: Any])
        let test = try #require(defs["test"] as? [String: Any])
        let variants = try #require(test["oneOf"] as? [[String: Any]])
        var kinds: [String: Set<String>] = [:]
        for variant in variants {
            let properties = try #require(variant["properties"] as? [String: Any])
            let kind = try #require(properties["kind"] as? [String: Any])
            let name = try #require(kind["const"] as? String)
            kinds[name] = Set(properties.keys)
        }
        #expect(Set(kinds.keys) == ["unit", "harness", "script"])
        let script = ManifestTest.script(.init(
            step: 0, inputs: ["a": "b"], fixtures: "f", expect: "e", expectContains: "c",
            expectFiles: ["x"], expectMissing: ["y"]
        ))
        #expect(try keys(script).isSubset(of: kinds["script"] ?? []))
        let harness = ManifestTest.harness(.init(setupText: "s", select: .all, expectText: "t"))
        #expect(try keys(harness).isSubset(of: kinds["harness"] ?? []))
    }
}
