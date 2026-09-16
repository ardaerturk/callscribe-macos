import Carbon.HIToolbox
import Foundation

private func callScribeHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData, let event else { return OSStatus(eventNotHandledErr) }
    let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
    var eventID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &eventID)
    guard status == noErr, eventID.signature == 0x43534352,
          eventID.id == hotKey.identifier else { return OSStatus(eventNotHandledErr) }
    DispatchQueue.main.async {
        hotKey.performAction()
    }
    return noErr
}

/// Registers a Carbon event hot key. This is deprecated but remains the native
/// macOS mechanism that works globally without Accessibility permission.
final class GlobalHotKey {
    private var hotKeyReference: EventHotKeyRef?
    private var handlerReference: EventHandlerRef?
    private let action: () -> Void
    fileprivate let identifier: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, identifier: UInt32, action: @escaping () -> Void) {
        self.action = action
        self.identifier = identifier

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callScribeHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerReference
        )
        guard handlerStatus == noErr else { return nil }

        let hotKeyID = EventHotKeyID(signature: 0x43534352, id: identifier) // CSCR
        let registrationStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyReference
        )
        guard registrationStatus == noErr else {
            if let handlerReference { RemoveEventHandler(handlerReference) }
            self.handlerReference = nil
            return nil
        }
    }

    deinit {
        if let hotKeyReference { UnregisterEventHotKey(hotKeyReference) }
        if let handlerReference { RemoveEventHandler(handlerReference) }
    }

    fileprivate func performAction() {
        action()
    }
}
