import AppKit
import ApplicationServices

// Private SkyLight calls (also used by yabai and AltTab). The public window list cannot tell a window on another
// Space from one that was closed but kept alive (ordered out), and Accessibility only reports the current Space.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?
@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
private func CGSCopyWindowsWithOptionsAndTags(
    _ cid: Int32, _ owner: Int32, _ spaces: CFArray, _ options: Int32,
    _ setTags: UnsafeMutablePointer<Int64>, _ clearTags: UnsafeMutablePointer<Int64>
) -> CFArray?

enum WindowScanner {
    /// Smaller layer-0 windows are helper surfaces (drag images, tooltips), not user windows.
    private static let minWindowSize: CGFloat = 50
    private static let axTimeout: Float = 0.15

    /// Of the given pids, those that own at least one window: placed on any Space, minimized, or belonging to a hidden app.
    static func pidsWithWindows(among pids: [pid_t]) -> Set<pid_t> {
        var found = pidsWithWindowsInSpaces()
        // Minimized windows and windows of hidden apps are on no Space; Accessibility still lists them.
        let rest = pids.filter { !found.contains($0) }
        var hits = [Bool](repeating: false, count: rest.count)
        hits.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: rest.count) { i in
                buffer[i] = hasAccessibilityWindow(rest[i])
            }
        }
        for (pid, hit) in zip(rest, hits) where hit {
            found.insert(pid)
        }
        return found
    }

    /// Whether the app has a window placed on any Space, i.e. one that is not minimized or hidden.
    static func hasWindowOnAnySpace(_ pid: pid_t) -> Bool {
        pidsWithWindowsInSpaces().contains(pid)
    }

    /// Unminimizes all of the app's minimized windows.
    static func restoreMinimizedWindows(of app: AXUIElement) {
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        for window in windows where attribute(window, kAXMinimizedAttribute) as? Bool == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
    }

    private static func pidsWithWindowsInSpaces() -> Set<pid_t> {
        let cid = CGSMainConnectionID()
        guard let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }
        let spaceIDs = displays.flatMap { display in
            (display["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["ManagedSpaceID"] as? Int }
        }
        var setTags: Int64 = 0
        var clearTags: Int64 = 0
        // Option 0x2 lists windows placed on the Spaces; 0x7 would add minimized and ordered-out windows.
        guard let ids = CGSCopyWindowsWithOptionsAndTags(cid, 0, spaceIDs as CFArray, 0x2, &setTags, &clearTags) as? [UInt32]
        else { return [] }
        let idSet = Set(ids)
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var pids = Set<pid_t>()
        for window in windows {
            guard let id = window[kCGWindowNumber as String] as? UInt32, idSet.contains(id),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= minWindowSize, bounds.height >= minWindowSize,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t
            else { continue }
            pids.insert(pid)
        }
        return pids
    }

    private static func hasAccessibilityWindow(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axTimeout)
        guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return false }
        return windows.contains { window in
            if attribute(window, kAXMinimizedAttribute) as? Bool == true { return true }
            let subrole = attribute(window, kAXSubroleAttribute) as? String
            return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
