import Foundation

/// JSON Schema (draft 2020-12) for `manifest.json`. M5 puts it in the agent's system
/// prompt; `ManifestSchemaTests` keeps it in step with the Swift types.
public enum ManifestSchema {
    public static let json = #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "title": "Automation manifest",
      "type": "object",
      "required": ["id", "trigger", "steps"],
      "additionalProperties": false,
      "properties": {
        "id": { "type": "string", "pattern": "^[a-z0-9-]+$", "description": "Folder name and stable id." },
        "name": { "type": "string" },
        "description": { "type": "string" },
        "request": { "type": "string", "description": "The user's original words." },
        "trigger": { "$ref": "#/$defs/trigger" },
        "steps": { "type": "array", "minItems": 1, "items": { "$ref": "#/$defs/step" } },
        "permissions": {
          "type": "array",
          "items": { "type": "string", "pattern": "^(accessibility|fullDiskAccess|screenRecording|automation:.+)$" }
        },
        "destructive": { "type": "boolean", "default": false },
        "tests": { "type": "array", "items": { "$ref": "#/$defs/test" } },
        "version": { "type": "integer", "minimum": 1, "default": 1 }
      },
      "$defs": {
        "trigger": {
          "oneOf": [
            {
              "type": "object",
              "required": ["type", "key"],
              "additionalProperties": false,
              "properties": {
                "type": { "const": "hotkey" },
                "key": { "type": "string", "description": "A-Z, 0-9, F1-F12, space, return, tab, escape, arrows." },
                "modifiers": { "type": "array", "items": { "enum": ["ctrl", "opt", "cmd", "shift"] } }
              }
            },
            {
              "type": "object",
              "required": ["type"],
              "additionalProperties": false,
              "properties": { "type": { "const": "manual" } }
            }
          ]
        },
        "step": {
          "type": "object",
          "required": ["type"],
          "properties": {
            "type": { "enum": ["primitive", "applescript", "jxa", "shell", "shortcut", "ax"] },
            "as": { "type": "string", "description": "Names this step's output for later {{name}} references." },
            "timeout": {
              "type": "number",
              "exclusiveMinimum": 0,
              "description": "Seconds. Defaults: primitive 10 (askText 300); applescript/jxa/shell 30; shortcut 60."
            },
            "action": {
              "enum": ["formatDate", "typeText", "pasteText", "readClipboard", "writeClipboard",
                       "notify", "openURL", "launchApp", "delay", "copySelection", "pressKeys", "askText"]
            },
            "keys": {
              "type": "string",
              "description": "pressKeys: modifiers (cmd, ctrl, opt, shift) and one key joined by +, e.g. cmd+shift+4."
            },
            "prompt": { "type": "string", "description": "askText: the question shown to the user." },
            "default": { "type": "string", "description": "askText: text the field starts with." },
            "pattern": { "type": "string", "description": "formatDate: Unicode date pattern, e.g. yyyy-MM-dd." },
            "text": { "type": "string" },
            "title": { "type": "string" },
            "url": { "type": "string" },
            "app": { "type": "string", "description": "launchApp: bundle id or app name." },
            "seconds": { "type": "number" },
            "file": { "type": "string", "description": "Script file relative to the manifest folder." },
            "source": { "type": "string", "description": "Inline script source." },
            "name": { "type": "string", "description": "shortcut: the shortcut's name." },
            "input": { "type": "string" }
          }
        },
        "test": {
          "oneOf": [
            {
              "type": "object",
              "required": ["kind", "step", "expect"],
              "additionalProperties": false,
              "properties": {
                "kind": { "const": "unit" },
                "step": { "type": "integer", "minimum": 0 },
                "clock": { "type": "string", "format": "date-time" },
                "clipboard": { "type": "string" },
                "expect": { "type": "string" }
              }
            },
            {
              "type": "object",
              "required": ["kind", "expectText"],
              "additionalProperties": false,
              "properties": {
                "kind": { "const": "harness" },
                "fire": { "enum": ["trigger", "handler"], "default": "trigger" },
                "expectText": { "type": "string" }
              }
            }
          ]
        }
      }
    }
    """#
}
