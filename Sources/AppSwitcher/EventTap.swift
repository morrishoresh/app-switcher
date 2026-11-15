import AppKit

/// Session-level keyboard tap. It sees ⌘⇥ before the Dock does, so swallowing it suppresses the built-in switcher.
final class EventTap {
    private let controller: SwitcherController
    private var tap: CFMachPort?

    init(controller: SwitcherController) {
        self.controller = controller
    }

    var isInstalled: Bool { tap != nil }

    /// While disabled the tap stays installed but receives nothing, so ⌘⇥ reaches the built-in switcher.
    var isEnabled = true {
        didSet {
            if let tap { CGEvent.tapEnable(tap: tap, enable: isEnabled) }
        }
    }

    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: isEnabled)
        self.tap = tap
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap, isEnabled { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        case .keyDown:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            return controller.keyDown(code, flags: event.flags, isRepeat: isRepeat) ? nil : pass
        case .keyUp:
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            return controller.keyUp(code) ? nil : pass
        case .flagsChanged:
            controller.flagsChanged(event.flags)
            return pass
        default:
            return pass
        }
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
