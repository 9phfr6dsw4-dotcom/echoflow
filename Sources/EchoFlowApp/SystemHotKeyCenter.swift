import Carbon.HIToolbox
import EchoFlowCore

private let echoFlowHotKeySignature: OSType = 0x4543_464C // "ECFL"

/// Registers key chords as system hotkeys. macOS delivers a registered chord only to EchoFlow,
/// so the frontmost app never receives it (and never beeps for an unknown shortcut or its key
/// repeats). Presses are reported once per physical press; key repeats and releases are ignored.
@MainActor
final class SystemHotKeyCenter {
    private struct Registration {
        let reference: EventHotKeyRef
        let onPress: @MainActor () -> Void
        var isPressed = false
    }

    private var handlerReference: EventHandlerRef?
    private var registrations: [UInt32: Registration] = [:]

    /// Returns false when the chord cannot be registered (an fn chord, which Carbon does not
    /// support, or a chord another app already owns); callers then keep their own listener.
    func register(
        id: UInt32,
        shortcut: KeyboardShortcutDescriptor,
        onPress: @escaping @MainActor () -> Void
    ) -> Bool {
        unregister(id: id)
        guard !shortcut.requiredModifierFlags.contains(.function), installHandlerIfNeeded() else { return false }
        var modifiers: UInt32 = 0
        if shortcut.requiredModifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if shortcut.requiredModifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if shortcut.requiredModifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if shortcut.requiredModifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }

        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            modifiers,
            EventHotKeyID(signature: echoFlowHotKeySignature, id: id),
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { return false }
        registrations[id] = Registration(reference: reference, onPress: onPress)
        return true
    }

    func unregister(id: UInt32) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(registration.reference)
    }

    func unregisterAll() {
        for id in Array(registrations.keys) {
            unregister(id: id)
        }
    }

    fileprivate func handle(id: UInt32, isPress: Bool) {
        guard var registration = registrations[id] else { return }
        if isPress {
            guard !registration.isPressed else { return }
            registration.isPressed = true
            registrations[id] = registration
            registration.onPress()
        } else {
            registration.isPressed = false
            registrations[id] = registration
        }
    }

    private func installHandlerIfNeeded() -> Bool {
        if handlerReference != nil { return true }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            echoFlowHotKeyEventHandler,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerReference
        )
        return status == noErr && handlerReference != nil
    }
}

private func echoFlowHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == echoFlowHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    let id = hotKeyID.id
    let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    let center = Unmanaged<SystemHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
    // Carbon delivers application events on the main thread.
    MainActor.assumeIsolated {
        center.handle(id: id, isPress: isPress)
    }
    return noErr
}
