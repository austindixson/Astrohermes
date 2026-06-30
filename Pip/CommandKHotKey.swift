import AppKit
import Carbon.HIToolbox

private enum CommandKHotKeyIDs {
    static let signature: OSType = 0x5069704B // 'PipK'
    static let identifier: UInt32 = 1
}

/// System-wide ⌘K via Carbon `RegisterEventHotKey` — works without focus or Accessibility.
final class CommandKHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
        register()
    }

    deinit {
        unregister()
    }

    private func register() {
        var hotKeyID = EventHotKeyID(signature: CommandKHotKeyIDs.signature, id: CommandKHotKeyIDs.identifier)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_K),
            UInt32(cmdKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            pipCommandKHotKeyHandler,
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )
        if handlerStatus != noErr {
            unregister()
        }
    }

    fileprivate func handlePress() {
        DispatchQueue.main.async { [onPress] in onPress() }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }
}

private func pipCommandKHotKeyHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var receivedID = EventHotKeyID()
    let paramStatus = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &receivedID
    )
    guard paramStatus == noErr,
          receivedID.signature == CommandKHotKeyIDs.signature,
          receivedID.id == CommandKHotKeyIDs.identifier else {
        return OSStatus(eventNotHandledErr)
    }

    let instance = Unmanaged<CommandKHotKey>.fromOpaque(userData).takeUnretainedValue()
    instance.handlePress()
    return noErr
}