import AppKit
import ApplicationServices

/// A running app's Dock icon under the pointer.
struct DockItem {
    let app: NSRunningApplication
    /// Icon frame in Cocoa screen coordinates (origin at the bottom left of the main screen).
    let frame: NSRect
}

/// Follows which Dock icon the pointer is on. The Dock reports that as the selected child of its icon list.
final class DockObserver {
    var onChange: ((DockItem?) -> Void)?
    private static let dockBundleID = "com.apple.dock"
    private var observer: AXObserver?
    private var dockList: AXUIElement?
    private var workspaceObservers: [NSObjectProtocol] = []

    /// Returns false while Accessibility access is missing.
    @discardableResult
    func start() -> Bool {
        if workspaceObservers.isEmpty {
            // The Dock restarts after crashes and `killall Dock`; attach to the new process.
            let center = NSWorkspace.shared.notificationCenter
            workspaceObservers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == Self.dockBundleID else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.attach() }
            })
        }
        return attach()
    }

    func stop() {
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        detach()
    }

    @discardableResult
    private func attach() -> Bool {
        detach()
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first else { return false }
        let pid = dock.processIdentifier
        let dockElement = AXUIElementCreateApplication(pid)
        var created: AXObserver?
        guard AXObserverCreate(pid, dockObserverCallback, &created) == .success, let created else { return false }
        let result = AXObserverAddNotification(created, dockElement, kAXSelectedChildrenChangedNotification as CFString,
                                               Unmanaged.passUnretained(self).toOpaque())
        guard result == .success else {
            log.error("Observing the Dock failed: \(result.rawValue)")
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        dockList = (WindowScanner.attribute(dockElement, kAXChildrenAttribute) as? [AXUIElement])?.first {
            WindowScanner.attribute($0, kAXRoleAttribute) as? String == kAXListRole
        }
        log.info("Observing the Dock")
        return true
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        dockList = nil
        onChange?(nil)
    }

    /// The running app's icon the Dock has under the pointer now, read directly rather than from notifications.
    func currentItem() -> DockItem? {
        let selected = dockList.flatMap { WindowScanner.attribute($0, kAXSelectedChildrenAttribute) as? [AXUIElement] }
        return selected?.first.flatMap(Self.runningAppItem)
    }

    fileprivate func selectionChanged(_ element: AXUIElement) {
        let list = WindowScanner.attribute(element, kAXRoleAttribute) as? String == kAXListRole ? element : dockList
        let selected = list.flatMap { WindowScanner.attribute($0, kAXSelectedChildrenAttribute) as? [AXUIElement] }
        onChange?(selected?.first.flatMap(Self.runningAppItem))
    }

    private static func runningAppItem(_ element: AXUIElement) -> DockItem? {
        guard WindowScanner.attribute(element, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
              let url = WindowScanner.attribute(element, kAXURLAttribute) as? URL,
              let frame = frame(of: element)
        else { return nil }
        let path = url.standardizedFileURL.path
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleURL?.standardizedFileURL.path == path && !$0.isTerminated
        }) else { return nil }
        return DockItem(app: app, frame: frame)
    }

    /// Accessibility frames have their origin at the top left of the main screen; Cocoa's is at the bottom left.
    private static func frame(of element: AXUIElement) -> NSRect? {
        guard let positionValue = WindowScanner.attribute(element, kAXPositionAttribute),
              let sizeValue = WindowScanner.attribute(element, kAXSizeAttribute) else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              let mainHeight = NSScreen.screens.first?.frame.height
        else { return nil }
        return NSRect(x: position.x, y: mainHeight - position.y - size.height, width: size.width, height: size.height)
    }
}

private func dockObserverCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    Unmanaged<DockObserver>.fromOpaque(refcon).takeUnretainedValue().selectionChanged(element)
}
