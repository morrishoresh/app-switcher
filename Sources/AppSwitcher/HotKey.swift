import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut through Carbon's hot keys, which need no Accessibility access and keep the key from the
/// frontmost app.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var releaseHandlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var isHandlerInstalled = false

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// `modifiers` are Carbon modifier flags, such as `cmdKey`. `onRelease` runs when the key goes up.
    init(keyCode: Int, modifiers: Int, onRelease: (() -> Void)? = nil, action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        Self.handlers[id] = action
        Self.releaseHandlers[id] = onRelease
        Self.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4153_5754), id: id) // "ASWT"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status != noErr { log.error("Hot key registration failed: \(status)") }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        Self.handlers[id] = nil
        Self.releaseHandlers[id] = nil
    }

    private static func installHandler() {
        guard !isHandlerInstalled else { return }
        isHandlerInstalled = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                HotKey.releaseHandlers[hotKeyID.id]?()
            } else {
                HotKey.handlers[hotKeyID.id]?()
            }
            return noErr
        }, specs.count, &specs, nil, nil)
    }
}
