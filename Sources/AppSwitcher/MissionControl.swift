import AppKit

/// Finds from the on-screen windows whether Mission Control, App Exposé or Show Desktop is showing; the Dock posts no
/// notification for them.
enum MissionControl {
    /// Layer of the Dock's window that covers each screen while Mission Control or App Exposé is showing.
    private static let overlayLayer = 20
    /// Show Desktop leaves this much, at most, of each window on screen, at a screen edge.
    private static let shownDesktopEdge: CGFloat = 24
    /// Smaller windows, such as helper windows of WindowManager and Slack, are left out of the Show Desktop check.
    private static let minWindowSize: CGFloat = 100

    /// Whether Mission Control or App Exposé is showing; `list` is the on-screen window list.
    static func isShowing(in list: [[String: Any]]) -> Bool {
        guard let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        else { return false }
        let screenSizes = NSScreen.screens.map(\.frame.size)
        return list.contains { window in
            guard window[kCGWindowOwnerPID as String] as? pid_t == dockPID,
                  window[kCGWindowLayer as String] as? Int == overlayLayer,
                  let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap(CGRect.init(dictionaryRepresentation:))
            else { return false }
            return screenSizes.contains(bounds.size)
        }
    }

    /// Whether Show Desktop is showing: it moves every app window to a screen edge, leaving a strip of it on screen.
    /// `frames` are the app windows' frames, in window-server coordinates.
    static func isDesktopShown(windowFrames frames: [CGRect]) -> Bool {
        var displayCount: UInt32 = 0
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &displayCount) == .success else { return false }
        let screens = displays.prefix(Int(displayCount)).map(CGDisplayBounds)
        let windows = frames.filter { min($0.width, $0.height) >= minWindowSize }
        return !windows.isEmpty && windows.allSatisfy { frame in
            screens.allSatisfy { screen in
                let visible = frame.intersection(screen)
                return visible.isNull || min(visible.width, visible.height) <= shownDesktopEdge
            }
        }
    }
}
