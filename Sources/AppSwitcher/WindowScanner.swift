import AppKit
import ApplicationServices

// Private SkyLight calls (also used by yabai and AltTab). The public window list cannot tell a window on another
// Space from one that was closed but kept alive (ordered out), and Accessibility only reports the current Space.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?
@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: Int32) -> Int
@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
private func CGSCopyWindowsWithOptionsAndTags(
    _ cid: Int32, _ owner: Int32, _ spaces: CFArray, _ options: Int32,
    _ setTags: UnsafeMutablePointer<Int64>, _ clearTags: UnsafeMutablePointer<Int64>
) -> CFArray?

enum WindowScanner {
    /// Smaller layer-0 windows are helper surfaces (drag images, tooltips), not user windows.
    private static let minWindowSize: CGFloat = 50
    private static let axTimeout: Float = 0.15
    /// In full screen, the toolbar is a separate window across the top, about 50 pt tall; full-screen windows are taller.
    private static let minFullScreenWindowHeight: CGFloat = 100
    /// `type` of a full-screen Space in the managed display spaces.
    private static let fullScreenSpaceType = 4

    /// Of the given pids, those that own at least one window: placed on any Space, minimized, or belonging to a hidden app.
    static func pidsWithWindows(among pids: [pid_t], spaceWindows: [[String: Any]]? = nil) -> Set<pid_t> {
        var found = spaceWindows.map { Set($0.compactMap { $0[kCGWindowOwnerPID as String] as? pid_t }) } ?? pidsWithWindowsInSpaces()
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

    /// Each app's frontmost window placed on any Space.
    static func frontWindows(in spaceWindows: [[String: Any]]? = nil) -> [pid_t: CGWindowID] {
        var front: [pid_t: CGWindowID] = [:]
        for window in spaceWindows ?? windowsInSpaces() {
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  let id = window[kCGWindowNumber as String] as? CGWindowID, front[pid] == nil else { continue }
            front[pid] = id
        }
        return front
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
        Set(windowsInSpaces().compactMap { $0[kCGWindowOwnerPID as String] as? pid_t })
    }

    /// Window-list entries of user windows placed on any Space, front to back.
    static func windowsInSpaces() -> [[String: Any]] {
        let cid = CGSMainConnectionID()
        guard let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return [] }
        let spaces = displays.flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }
        let spaceIDs = spaces.compactMap { $0["ManagedSpaceID"] as? Int }
        let fullScreenSpaceIDs = spaces.filter { $0["type"] as? Int == fullScreenSpaceType }.compactMap { $0["ManagedSpaceID"] as? Int }
        let idSet = Set(windowIDs(cid, spaces: spaceIDs))
        let fullScreenIDs = fullScreenSpaceIDs.isEmpty ? [] : Set(windowIDs(cid, spaces: fullScreenSpaceIDs))
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.filter { window in
            guard let id = window[kCGWindowNumber as String] as? UInt32, idSet.contains(id),
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return false }
            let minHeight = fullScreenIDs.contains(id) ? minFullScreenWindowHeight : minWindowSize
            return bounds.width >= minWindowSize && bounds.height >= minHeight
        }
    }

    /// Display identifier in the managed display spaces when all displays share their Spaces.
    static let sharedSpacesDisplay = "Main"

    /// The Space a display now shows.
    struct DisplaySpace {
        /// Display UUID, or `sharedSpacesDisplay`.
        let display: String
        /// Space UUID; empty for the first desktop.
        let space: String
        let isFullScreen: Bool
    }

    /// The Space each display now shows, and the windows on those that are full-screen Spaces.
    static func currentSpaces() -> (spaces: [DisplaySpace], fullScreenWindows: Set<UInt32>) {
        let cid = CGSMainConnectionID()
        guard let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] else { return ([], []) }
        var spaces: [DisplaySpace] = []
        var fullScreenIDs: [Int] = []
        for display in displays {
            guard let current = display["Current Space"] as? [String: Any], let displayID = display["Display Identifier"] as? String
            else { continue }
            let isFullScreen = current["type"] as? Int == fullScreenSpaceType
            spaces.append(DisplaySpace(display: displayID, space: current["uuid"] as? String ?? "", isFullScreen: isFullScreen))
            if isFullScreen, let spaceID = current["ManagedSpaceID"] as? Int { fullScreenIDs.append(spaceID) }
        }
        return (spaces, fullScreenIDs.isEmpty ? [] : Set(windowIDs(cid, spaces: fullScreenIDs)))
    }

    /// UUID of the Space with the keyboard focus; empty for the first desktop.
    static func activeSpace() -> String? {
        let cid = CGSMainConnectionID()
        let active = CGSGetActiveSpace(cid)
        let displays = CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]] ?? []
        let space = displays.flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }.first { $0["ManagedSpaceID"] as? Int == active }
        return space.map { $0["uuid"] as? String ?? "" }
    }

    /// UUIDs of all desktops and full-screen Spaces.
    static func allSpaces() -> [String] {
        let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
        return displays.flatMap { $0["Spaces"] as? [[String: Any]] ?? [] }.map { $0["uuid"] as? String ?? "" }
    }

    private static func windowIDs(_ cid: Int32, spaces: [Int]) -> [UInt32] {
        var setTags: Int64 = 0
        var clearTags: Int64 = 0
        // Option 0x2 lists windows placed on the Spaces; 0x7 would add minimized and ordered-out windows.
        return CGSCopyWindowsWithOptionsAndTags(cid, 0, spaces as CFArray, 0x2, &setTags, &clearTags) as? [UInt32] ?? []
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

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
