import Foundation
@testable import Shared
import Testing

struct KeyCodesTests {
    @Test func lettersAreCaseInsensitive() {
        #expect(KeyCodes.virtualKeyCode(for: "d") == 0x02)
        #expect(KeyCodes.virtualKeyCode(for: "D") == 0x02)
        #expect(KeyCodes.virtualKeyCode(for: "A") == 0x00)
    }

    @Test func namedKeys() {
        #expect(KeyCodes.virtualKeyCode(for: "F5") == 0x60)
        #expect(KeyCodes.virtualKeyCode(for: "f5") == 0x60)
        #expect(KeyCodes.virtualKeyCode(for: "space") == 0x31)
        #expect(KeyCodes.virtualKeyCode(for: "Return") == 0x24)
        #expect(KeyCodes.virtualKeyCode(for: "7") == 0x1A)
    }

    @Test func unknownKeyIsNil() {
        #expect(KeyCodes.virtualKeyCode(for: "Hyper") == nil)
        #expect(KeyCodes.virtualKeyCode(for: "") == nil)
    }

    @Test func carbonModifiers() {
        #expect(KeyCodes.carbonModifiers([]) == 0)
        #expect(KeyCodes.carbonModifiers([.cmd]) == 256)
        #expect(KeyCodes.carbonModifiers([.shift]) == 1 << 9)
        #expect(KeyCodes.carbonModifiers([.ctrl, .opt, .cmd]) == (1 << 12) | (1 << 11) | (1 << 8))
        #expect(KeyCodes.carbonModifiers([.cmd, .cmd]) == 256)
    }
}
