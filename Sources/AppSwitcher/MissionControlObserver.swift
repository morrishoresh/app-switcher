import AppKit
import ApplicationServices

/// Tells whether Mission Control or App Exposé is showing. While either is on screen, the Dock has a window at layer 20
/// covering a screen; it appears a moment after opening starts, so the Dock's Accessibility notification for opening
/// is observed too, to react without waiting for it.
final class MissionControlObserver {
    /// Called when Mission Control or App Exposé starts opening.
    var onShow: (() -> Void)?
    private static let dockBundleID = "com.apple.dock"
    private static let showNotifications = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows"]
    /// Layer of the Dock's window that covers each screen while Mission Control or App Exposé is showing.
    private static let overlayLayer = 20
    /// Time after the opening notification that counts as showing even before the Dock's window appears.
    private static let showGrace: TimeInterval = 0.5
    private var shownAt: Date?
    private var observer: AXObserver?
    private var workspaceObserver: NSObjectProtocol?

    func start() {
        if workspaceObserver == nil {
            // The Dock restarts after crashes and `killall Dock`; attach to the new process.
            workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == Self.dockBundleID else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.attach() }
            }
        }
        attach()
    }

    func stop() {
        workspaceObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObserver = nil
        detach()
    }

    /// Whether Mission Control or App Exposé is showing; `list` is the on-screen window list.
    func isShown(in list: [[String: Any]]) -> Bool {
        if let shownAt, Date().timeIntervalSince(shownAt) < Self.showGrace { return true }
        guard let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first?.processIdentifier
        else { return false }
        let screenSizes = NSScreen.screens.map(\.frame.size)
        return list.contains { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == dockPID,
                  window[kCGWindowLayer as String] as? Int == Self.overlayLayer,
                  let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap(CGRect.init(dictionaryRepresentation:))
            else { return false }
            return screenSizes.contains(bounds.size)
        }
    }

    /// Without Accessibility access nothing is observed; `isShown(in:)` then finds Mission Control from the window list
    /// only.
    private func attach() {
        detach()
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first?.processIdentifier
        else { return }
        let dock = AXUIElementCreateApplication(pid)
        var created: AXObserver?
        guard AXObserverCreate(pid, missionControlObserverCallback, &created) == .success, let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.showNotifications {
            let result = AXObserverAddNotification(created, dock, name as CFString, refcon)
            if result != .success { log.error("Observing \(name) failed: \(result.rawValue)") }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
    }

    fileprivate func showing() {
        shownAt = Date()
        onShow?()
    }
}

private func missionControlObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<MissionControlObserver>.fromOpaque(refcon).takeUnretainedValue().showing()
}
