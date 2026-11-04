import Foundation
@testable import Shared
import Testing

struct ManifestSchemaTests {
    private func schema() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(ManifestSchema.json.utf8))
        return try #require(object as? [String: Any])
    }

    private func definition(_ name: String) throws -> [String: Any] {
        let defs = try #require(try schema()["$defs"] as? [String: Any])
        return try #require(defs[name] as? [String: Any])
    }

    @Test func parses() throws {
        let root = try schema()
        #expect(root["type"] as? String == "object")
        #expect(root["required"] as? [String] == ["id", "trigger", "steps"])
    }

    @Test func primitiveActionsMatch() throws {
        let properties = try #require(try definition("step")["properties"] as? [String: Any])
        let action = try #require(properties["action"] as? [String: Any])
        let names = try #require(action["enum"] as? [String])
        #expect(names == Primitive.actionNames)
    }

    @Test func stepTypesMatch() throws {
        let properties = try #require(try definition("step")["properties"] as? [String: Any])
        let type = try #require(properties["type"] as? [String: Any])
        let names = try #require(type["enum"] as? [String])
        let bodies: [Step.Body] = [
            .primitive(.readClipboard),
            .applescript(ScriptSource(source: "")),
            .jxa(ScriptSource(source: "")),
            .shell(ScriptSource(source: "")),
            .shortcut(name: "", input: nil),
            .accessibility(action: "")
        ]
        #expect(names == bodies.map(\.typeName))
    }

    @Test func topLevelPropertiesMatchManifestKeys() throws {
        let properties = try #require(try schema()["properties"] as? [String: Any])
        let expected: Set<String> = [
            "id", "name", "description", "request", "trigger", "steps",
            "permissions", "destructive", "tests", "version"
        ]
        #expect(Set(properties.keys) == expected)
    }

    @Test func encodedManifestKeysAreInSchema() throws {
        let example = try AutomationManifest.decode(from: Data(ExampleManifests.insertISODate.utf8))
        let encoded = try #require(try JSONSerialization.jsonObject(with: example.encoded()) as? [String: Any])
        let properties = try #require(try schema()["properties"] as? [String: Any])
        #expect(Set(encoded.keys).isSubset(of: Set(properties.keys)))
    }
}
