import Foundation

/// Manifests shipped with the app for trying the runner before the agent exists.
public enum ExampleManifests {
    /// The handoff doc's first end-to-end target: ⌃⌥⌘D types today's date.
    public static let insertISODate = """
    {
      "id": "insert-iso-date",
      "name": "Insert today's date",
      "description": "Types today's date as yyyy-MM-dd at the cursor.",
      "request": "When I press ctrl-opt-cmd-D, type today's date as yyyy-MM-dd",
      "trigger": { "type": "hotkey", "key": "D", "modifiers": ["ctrl", "opt", "cmd"] },
      "steps": [
        { "type": "primitive", "action": "formatDate", "pattern": "yyyy-MM-dd", "as": "date" },
        { "type": "primitive", "action": "typeText", "text": "{{date}}" }
      ],
      "permissions": ["accessibility"],
      "destructive": false,
      "tests": [
        { "kind": "unit", "step": 0, "clock": "2024-12-30T12:00:00Z", "expect": "2024-12-30" },
        { "kind": "unit", "step": 1, "clock": "2024-12-30T12:00:00Z", "expect": "2024-12-30" },
        { "kind": "harness", "fire": "trigger", "expectText": "{{today:yyyy-MM-dd}}" }
      ],
      "version": 1
    }
    """
}
