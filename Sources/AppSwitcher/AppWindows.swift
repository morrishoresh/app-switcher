import AppKit
import ApplicationServices

struct TabInfo {
    let title: String
    let isSelected: Bool
    let element: AXUIElement
}

struct WindowInfo {
    let id: CGWindowID
    let title: String
    let isMinimized: Bool
    /// Placed on a Space (current or other), so ScreenCaptureKit can capture its current content; minimized windows
    /// and windows of a hidden app are not.
    let isOnSpace: Bool
    /// Missing for windows on other Spaces: Accessibility only reports the current Space.
    let element: AXUIElement?
    /// Tabs of the window's tab bar; empty without one.
    let tabs: [TabInfo]
}

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError
@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?
@_silgen_name("GetProcessForPID")
private func getProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

/// Lists one app's windows with their tabs, and brings a chosen window or tab to the front.
enum AppWindows {
    private static let axTimeout: Float = 0.25
    private static let tabSearchDepth = 8
    private static let tabSearchMaxElements = 600
    /// Depth of tabs below their tab group. Firefox nests them in a scroll box and in tab groups.
    private static let tabDepthInGroup = 4
    private static let accessibilityStartDelay: TimeInterval = 0.5
    /// Accessibility element IDs tried when looking up windows on other Spaces; apps number their elements from 0.
    private static let elementIDSearchLimit: UInt64 = 1000
    private static let accessibilityLock = NSLock()
    nonisolated(unsafe) private static var accessibilityEnabledPids = Set<pid_t>()
    /// Subtrees that hold document content, never a window's tab bar; skipping them keeps the search short.
    private static let contentRoles: Set<String> = [
        "AXWebArea", "AXScrollArea", "AXTable", "AXOutline", "AXBrowser", "AXTextArea", "AXList",
    ]

    /// Windows on any Space front to back, then minimized windows and windows of a hidden app. `spaceWindows` is
    /// `WindowScanner.windowsInSpaces()`, passed in when listing several apps; without `includeTabs`, tabs are left
    /// empty, which skips the slowest Accessibility calls.
    static func windows(of app: NSRunningApplication, spaceWindows: [[String: Any]]? = nil,
                        includeTabs: Bool = true) -> [WindowInfo] {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, axTimeout)
        let listTabs: (AXUIElement) -> [TabInfo] = includeTabs ? Self.tabs(of:) : { _ in [] }
        if includeTabs, enableAccessibility(of: app, appElement) {
            // Firefox builds its accessibility tree asynchronously after being asked to.
            Thread.sleep(forTimeInterval: accessibilityStartDelay)
        }
        let listed = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement]
        let axWindows = (listed ?? []).compactMap { window in
            windowID(of: window).map { (id: $0, element: window) }
        }
        var axByID = Dictionary(axWindows.map { ($0.id, $0.element) }, uniquingKeysWith: { first, _ in first })
        let spaceEntries = (spaceWindows ?? WindowScanner.windowsInSpaces()).filter { $0[kCGWindowOwnerPID as String] as? pid_t == pid }

        // Windows on other Spaces are missing from the list; without their elements there are no tabs and no AXRaise,
        // and macOS switches Space only on AXRaise. A failed list means the app is not answering, so skip the search.
        let missing = Set(spaceEntries.compactMap { $0[kCGWindowNumber as String] as? CGWindowID }).subtracting(axByID.keys)
        if listed != nil, !missing.isEmpty {
            axByID.merge(windowElements(pid: pid, ids: missing)) { first, _ in first }
        }

        var result: [WindowInfo] = []
        for entry in spaceEntries {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            let element = axByID[id]
            let axTitle = element.flatMap { attribute($0, kAXTitleAttribute) as? String }
            result.append(WindowInfo(
                id: id,
                title: nonEmpty(axTitle) ?? nonEmpty(entry[kCGWindowName as String] as? String) ?? "",
                isMinimized: false,
                isOnSpace: true,
                element: element,
                tabs: element.map(listTabs) ?? []
            ))
        }

        // Minimized windows and windows of a hidden app are on no Space. Other Accessibility windows that are on no
        // Space are background tabs or windows that were closed but kept alive, so they are left out.
        let placed = Set(result.map(\.id))
        for (id, element) in axWindows where !placed.contains(id) {
            let minimized = attribute(element, kAXMinimizedAttribute) as? Bool == true
            let subrole = attribute(element, kAXSubroleAttribute) as? String
            guard minimized || (app.isHidden && (subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole))
            else { continue }
            result.append(WindowInfo(
                id: id,
                title: attribute(element, kAXTitleAttribute) as? String ?? "",
                isMinimized: minimized,
                isOnSpace: false,
                element: element,
                tabs: listTabs(element)
            ))
        }
        return result
    }

    /// Window elements found by trying element IDs, as AltTab does: the remote token addresses one element of the app.
    private static func windowElements(pid: pid_t, ids: Set<CGWindowID>) -> [CGWindowID: AXUIElement] {
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        var found: [CGWindowID: AXUIElement] = [:]
        for elementID in 0..<elementIDSearchLimit where found.count < ids.count {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            guard let element = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, axTimeout)
            if let id = windowID(of: element), ids.contains(id),
               attribute(element, kAXRoleAttribute) as? String == kAXWindowRole {
                found[id] = element
            }
        }
        return found
    }

    /// Firefox exposes its window contents, tab bar included, only once an assistive app asks for them, as VoiceOver does
    /// by setting AXEnhancedUserInterface. Returns true when the request was sent now, once per process.
    private static func enableAccessibility(of app: NSRunningApplication, _ element: AXUIElement) -> Bool {
        guard app.bundleIdentifier?.hasPrefix("org.mozilla.") == true else { return false }
        let pid = app.processIdentifier
        let isNew = accessibilityLock.withLock { accessibilityEnabledPids.insert(pid).inserted }
        guard isNew else { return false }
        AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        log.info("Requested accessibility from \(app.localizedName ?? "", privacy: .public)")
        return true
    }

    /// Presses the window's close button. Returns false when it has none.
    @discardableResult
    static func close(_ window: WindowInfo) -> Bool {
        guard let element = window.element, let button = attribute(element, kAXCloseButtonAttribute),
              CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Presses the close button inside the tab. Returns false when it has none.
    @discardableResult
    static func close(_ tab: TabInfo) -> Bool {
        guard let button = closeButton(in: tab.element, depth: 0) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    /// A tab's close button: a button marked as a close button, or described as one ("Close Tab" in Firefox and Safari).
    private static func closeButton(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 3 else { return nil }
        for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if attribute(child, kAXRoleAttribute) as? String == kAXButtonRole {
                let subrole = attribute(child, kAXSubroleAttribute) as? String
                let text = [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute]
                    .compactMap { attribute(child, $0) as? String }.joined(separator: " ").lowercased()
                if subrole == kAXCloseButtonSubrole || text.contains("close") { return child }
            }
            if let found = closeButton(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    /// Brings the window to the front, switching Space if needed; with `tab`, selects that tab first.
    static func focus(_ window: WindowInfo, of app: NSRunningApplication, tab: TabInfo? = nil) {
        if app.isHidden {
            app.unhide()
        }
        if let element = window.element {
            if window.isMinimized {
                AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            if let tab {
                AXUIElementPerformAction(tab.element, kAXPressAction as CFString)
            }
        }
        if !SkyLight.makeKeyWindow(window.id, pid: app.processIdentifier) {
            app.activate()
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                         kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }
        if let element = window.element {
            AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
    }

    /// The tabs of the shallowest tab group (radio buttons inside an AXTabGroup) with at least two tabs.
    private static func tabs(of window: AXUIElement) -> [TabInfo] {
        var level = [window]
        var visited = 0
        for _ in 0..<tabSearchDepth where !level.isEmpty && visited < tabSearchMaxElements {
            var next: [AXUIElement] = []
            for element in level {
                for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                    visited += 1
                    let role = attribute(child, kAXRoleAttribute) as? String ?? ""
                    if role == kAXTabGroupRole {
                        let tabs = tabButtons(in: child)
                        if tabs.count >= 2 { return tabs }
                    } else if !contentRoles.contains(role) {
                        next.append(child)
                    }
                }
            }
            level = next
        }
        return []
    }

    /// Radio buttons anywhere below the tab group, in tab-bar order; nested tab groups are left out.
    private static func tabButtons(in group: AXUIElement, depth: Int = 0) -> [TabInfo] {
        guard depth < tabDepthInGroup else { return [] }
        return (attribute(group, kAXChildrenAttribute) as? [AXUIElement] ?? []).flatMap { child -> [TabInfo] in
            switch attribute(child, kAXRoleAttribute) as? String {
            case kAXRadioButtonRole:
                let title = nonEmpty(attribute(child, kAXTitleAttribute) as? String)
                    ?? nonEmpty(attribute(child, kAXDescriptionAttribute) as? String) ?? ""
                let value = attribute(child, kAXValueAttribute)
                let selected = (value as? Bool) ?? ((value as? Int) == 1)
                return [TabInfo(title: title, isSelected: selected, element: child)]
            case kAXTabGroupRole:
                return []
            default:
                return tabButtons(in: child, depth: depth + 1)
            }
        }
    }

    /// The app's focused window.
    static func focusedWindowID(of pid: pid_t) -> CGWindowID? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, axTimeout)
        guard let window = attribute(appElement, kAXFocusedWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        return windowID(of: window as! AXUIElement)
    }

    private static func windowID(of window: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success && id != 0 ? id : nil
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        WindowScanner.attribute(element, name)
    }

    private static func nonEmpty(_ string: String?) -> String? {
        string?.isEmpty == false ? string : nil
    }

    /// Private SkyLight calls (as used by yabai and AltTab) that make one specific window key, switching to its Space.
    /// Resolved at run time, since SkyLight is a private framework with no SDK stub to link against.
    private enum SkyLight {
        private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
        private typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
        private static let userGenerated: UInt32 = 0x200

        private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        private static let setFrontProcess = symbol("_SLPSSetFrontProcessWithOptions", as: SetFrontProcess.self)
        private static let postEventRecord = symbol("SLPSPostEventRecordTo", as: PostEventRecord.self)

        private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }

        static func makeKeyWindow(_ windowID: CGWindowID, pid: pid_t) -> Bool {
            guard let setFrontProcess, let postEventRecord else { return false }
            var psn = ProcessSerialNumber()
            guard getProcessForPID(pid, &psn) == noErr,
                  setFrontProcess(&psn, windowID, userGenerated) == .success
            else { return false }
            // Synthetic key-window event pair, laid out as yabai's window_manager_make_key_window.
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xf8
            bytes[0x3a] = 0x10
            withUnsafeBytes(of: windowID) { bytes.replaceSubrange(0x3c..<0x40, with: $0) }
            bytes.replaceSubrange(0x20..<0x30, with: repeatElement(0xff, count: 0x10))
            bytes[0x08] = 0x01
            _ = postEventRecord(&psn, &bytes)
            bytes[0x08] = 0x02
            _ = postEventRecord(&psn, &bytes)
            return true
        }
    }
}
