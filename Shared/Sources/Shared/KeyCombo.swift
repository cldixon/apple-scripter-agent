import Foundation

/// A key combination for the `pressKeys` primitive, written like `cmd+shift+4`: any of the
/// modifiers `cmd`, `ctrl`, `opt`, `shift` (also `command`, `control`, `option`, `alt`) and
/// exactly one key name that `KeyCodes` knows, joined by `+`, case-insensitive.
public struct KeyCombo: Sendable, Equatable, CustomStringConvertible {
    public var modifiers: [Hotkey.Modifier]
    /// The key name as written, e.g. `4` or `space`.
    public var key: String
    public var keyCode: UInt32

    public init(modifiers: [Hotkey.Modifier], key: String, keyCode: UInt32) {
        self.modifiers = modifiers
        self.key = key
        self.keyCode = keyCode
    }

    /// Why a combination could not be read.
    public enum ParseError: Error, Equatable, LocalizedError {
        case noKey(String)
        case unknownKey(String)
        case severalKeys(String)

        public var errorDescription: String? {
            switch self {
            case .noKey(let text):
                "\"\(text)\" names no key. Write modifiers and one key, like cmd+shift+4."
            case .unknownKey(let key):
                "Unknown key \"\(key)\". Use A-Z, 0-9, punctuation, F1-F12, space, return, tab, "
                    + "escape, delete, forwardDelete, left, right, up, down, home, end, pageUp, pageDown."
            case .severalKeys(let text):
                "\"\(text)\" names more than one key. Write modifiers and one key, like cmd+shift+4."
            }
        }
    }

    private static let modifierNames: [String: Hotkey.Modifier] = [
        "cmd": .cmd, "command": .cmd,
        "ctrl": .ctrl, "control": .ctrl,
        "opt": .opt, "option": .opt, "alt": .opt,
        "shift": .shift
    ]

    /// Reads `cmd+shift+4`. Spaces around parts are ignored. The `+` key itself cannot be
    /// written; use `shift+=` instead.
    public static func parse(_ text: String) throws -> KeyCombo {
        let parts = text.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var modifiers: [Hotkey.Modifier] = []
        var keys: [String] = []
        for part in parts {
            if let modifier = modifierNames[part.lowercased()] {
                if !modifiers.contains(modifier) { modifiers.append(modifier) }
            } else if !part.isEmpty {
                keys.append(part)
            }
        }
        guard let key = keys.first else { throw ParseError.noKey(text) }
        guard keys.count == 1 else { throw ParseError.severalKeys(text) }
        guard let keyCode = KeyCodes.virtualKeyCode(for: key) else { throw ParseError.unknownKey(key) }
        return KeyCombo(modifiers: modifiers, key: key, keyCode: keyCode)
    }

    /// The combination in canonical form, e.g. `cmd+shift+4`.
    public var description: String {
        (modifiers.map(\.rawValue) + [key.lowercased()]).joined(separator: "+")
    }
}
