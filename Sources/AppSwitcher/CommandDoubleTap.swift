import AppKit

/// Watches for ⌘ tapped and then pressed again and held, in any app. Independent of the ⌘⇥ event tap, which is off
/// while the ⌘⇥ switcher is.
final class CommandDoubleTap {
    /// A ⌘ press shorter than this, with no other key, counts as a tap.
    private static let tapMaxDuration: TimeInterval = 0.4
    /// ⌘ pressed again within this time of a tap starts the hold.
    private static let interval: TimeInterval = 0.35

    /// ⌘ was tapped and is now held again.
    var onHoldStart: () -> Void = {}
    /// ⌘ was released after `onHoldStart`.
    var onHoldEnd: () -> Void = {}

    private var monitors: [Any] = []
    private var isCommandDown = false
    private var isHolding = false
    private var commandDownAt = Date.distantPast
    private var lastTapAt = Date.distantPast
    private var keyPressedDuringCommand = false

    /// Seeing key presses in other apps needs Accessibility access, so this starts once it is granted.
    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            keyPressedDuringCommand = true
            return
        }
        let commandDown = event.modifierFlags.contains(.command)
        guard commandDown != isCommandDown else { return }
        isCommandDown = commandDown
        let now = Date()
        if commandDown {
            commandDownAt = now
            keyPressedDuringCommand = false
            if now.timeIntervalSince(lastTapAt) <= Self.interval {
                isHolding = true
                onHoldStart()
            }
        } else {
            let isTap = !keyPressedDuringCommand && now.timeIntervalSince(commandDownAt) <= Self.tapMaxDuration
            // The held press itself does not start another double tap.
            lastTapAt = isTap && !isHolding ? now : .distantPast
            if isHolding {
                isHolding = false
                onHoldEnd()
            }
        }
    }
}
