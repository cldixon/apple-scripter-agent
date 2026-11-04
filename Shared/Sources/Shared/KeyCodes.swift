import Foundation

/// Maps manifest key names to macOS virtual key codes (ANSI layout) and modifiers to
/// Carbon modifier flags, for `RegisterEventHotKey` and synthetic key events.
public enum KeyCodes {
    private static let table: [String: UInt32] = [
        "A": 0x00, "S": 0x01, "D": 0x02, "F": 0x03, "H": 0x04, "G": 0x05, "Z": 0x06, "X": 0x07,
        "C": 0x08, "V": 0x09, "B": 0x0B, "Q": 0x0C, "W": 0x0D, "E": 0x0E, "R": 0x0F, "Y": 0x10,
        "T": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "O": 0x1F, "U": 0x20,
        "[": 0x21, "I": 0x22, "P": 0x23, "RETURN": 0x24, "L": 0x25, "J": 0x26, "'": 0x27,
        "K": 0x28, ";": 0x29, "\\": 0x2A, ",": 0x2B, "/": 0x2C, "N": 0x2D, "M": 0x2E, ".": 0x2F,
        "TAB": 0x30, "SPACE": 0x31, "`": 0x32, "DELETE": 0x33, "ESCAPE": 0x35,
        "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76, "F5": 0x60, "F6": 0x61,
        "F7": 0x62, "F8": 0x64, "F9": 0x65, "F10": 0x6D, "F11": 0x67, "F12": 0x6F,
        "LEFT": 0x7B, "RIGHT": 0x7C, "DOWN": 0x7D, "UP": 0x7E
    ]

    /// Key code for a manifest key name such as `D`, `7`, `F5` or `space` (case-insensitive).
    public static func virtualKeyCode(for key: String) -> UInt32? {
        table[key.uppercased()]
    }

    /// Carbon modifier flags (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    public static func carbonModifiers(_ modifiers: [Hotkey.Modifier]) -> UInt32 {
        modifiers.reduce(0) { flags, modifier in
            switch modifier {
            case .cmd: flags | (1 << 8)
            case .shift: flags | (1 << 9)
            case .opt: flags | (1 << 11)
            case .ctrl: flags | (1 << 12)
            }
        }
    }
}
