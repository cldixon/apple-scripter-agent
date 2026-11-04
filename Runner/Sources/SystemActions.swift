import AppKit
import ApplicationServices
import Shared

/// Everything that touches AppKit, the pasteboard or synthetic key events. Main actor only.
@MainActor
enum SystemActions {
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system Accessibility prompt (once per app) and opens the settings pane.
    static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Keyboard

    /// Types `text` into the focused field as Unicode key events.
    static func type(_ text: String) async throws {
        try requireAccessibility()
        await waitForModifierRelease()
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        var start = 0
        while start < units.count {
            var end = min(start + 16, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
            let chunk = Array(units[start..<end])
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown) else {
                    throw AutomationError.system("Could not create a keyboard event.")
                }
                event.flags = []
                chunk.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                event.post(tap: .cghidEventTap)
            }
            start = end
            try await Task.sleep(for: .milliseconds(4))
        }
    }

    /// Puts `text` on the clipboard, presses ⌘V, then restores the previous clipboard text.
    static func paste(_ text: String) async throws {
        try requireAccessibility()
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        writeClipboard(text)
        await waitForModifierRelease()
        try press(keyCode: 0x09, flags: .maskCommand)
        try await Task.sleep(for: .milliseconds(250))
        if let previous { writeClipboard(previous) }
    }

    /// Posts one key press, for example a hotkey during a harness test.
    static func press(keyCode: UInt32, flags: CGEventFlags) throws {
        try requireAccessibility()
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: isDown)
            guard let event else {
                throw AutomationError.system("Could not create a keyboard event.")
            }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    static func eventFlags(for modifiers: [Hotkey.Modifier]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { flags, modifier in
            switch modifier {
            case .cmd: flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .opt: flags.insert(.maskAlternate)
            case .ctrl: flags.insert(.maskControl)
            }
        }
    }

    /// A hotkey fires while its modifiers are still held; typing then would turn letters into
    /// shortcuts. Wait (briefly) until the user lets go.
    private static func waitForModifierRelease() async {
        let held: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        for _ in 0..<50 {
            if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func requireAccessibility() throws {
        guard isAccessibilityTrusted else { throw AutomationError.permissionMissing(.accessibility) }
    }

    // MARK: Clipboard, URLs, apps

    static func readClipboard() -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }

    static func writeClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    static func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw AutomationError.system("macOS could not open \(url.absoluteString).")
        }
    }

    /// Launches an app given its bundle id (`com.apple.TextEdit`) or name (`TextEdit`).
    static func launch(_ app: String) async throws {
        guard let url = applicationURL(for: app) else {
            throw AutomationError.invalidArgument("No app named or identified as \"\(app)\" is installed.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func applicationURL(for app: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) { return url }
        let name = app.hasSuffix(".app") ? app : "\(app).app"
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                       "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        return folders
            .map { URL(filePath: $0).appending(path: name) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
