import Carbon.HIToolbox
import Foundation
import Shared

enum HotkeyError: LocalizedError {
    case unknownKey(String)
    case taken(String)
    case failed(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .unknownKey(let key): "Unknown key \"\(key)\"."
        case .taken(let hotkey): "\(hotkey) is already used by another app or automation."
        case .failed(let hotkey, let status): "Could not register \(hotkey) (error \(status))."
        }
    }
}

/// Registers global hotkeys with Carbon's `RegisterEventHotKey`, which needs no permission.
@MainActor
final class HotkeyCenter {
    private static let signature: OSType = 0x4141_6774 // "AAgt"

    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: @MainActor () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventCallback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
    }

    func register(_ hotkey: Hotkey, handler: @escaping @MainActor () -> Void) throws {
        guard let keyCode = KeyCodes.virtualKeyCode(for: hotkey.key) else {
            throw HotkeyError.unknownKey(hotkey.key)
        }
        let id = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            KeyCodes.carbonModifiers(hotkey.modifiers),
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else {
            if status == OSStatus(eventHotKeyExistsErr) { throw HotkeyError.taken(hotkey.displayString) }
            throw HotkeyError.failed(hotkey.displayString, status)
        }
        references[id] = reference
        handlers[id] = handler
    }

    func unregisterAll() {
        for reference in references.values {
            UnregisterEventHotKey(reference)
        }
        references.removeAll()
        handlers.removeAll()
    }

    fileprivate func fire(id: UInt32) {
        handlers[id]?()
    }
}

/// Carbon calls this on the main thread for every registered hotkey press.
private func hotkeyEventCallback(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )
    guard status == noErr else { return status }
    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        center.fire(id: hotkeyID.id)
    }
    return noErr
}
