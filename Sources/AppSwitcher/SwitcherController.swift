import AppKit

private enum KeyCode {
    static let tab = 48
    static let grave = 50
    static let escape = 53
    static let returnKey = 36
    static let enter = 76
    static let left = 123
    static let right = 124
    static let q = 12
    static let h = 4
}

/// The ⌘⇥ session: starts on ⌘⇥, cycles while ⌘ is held, switches on ⌘ release.
final class SwitcherController {
    /// Quick ⌘⇥ taps switch without flashing the panel.
    private static let panelDelay: TimeInterval = 0.12

    /// Also list apps without windows; switching to one opens a new window.
    var showsAppsWithoutWindows = false

    private let tracker: AppTracker
    private let panel = SwitcherPanel()
    private var entries: [SwitcherEntry] = []
    private var selected = 0
    private var isActive = false
    private var pendingShow: DispatchWorkItem?
    /// Key-ups are swallowed only for keys whose key-down was swallowed.
    private var swallowedKeys = Set<Int>()

    init(tracker: AppTracker) {
        self.tracker = tracker
        panel.onHover = { [weak self] index in self?.select(index) }
        panel.onClick = { [weak self] index in
            self?.select(index)
            self?.commit(restoreMinimized: false)
        }
    }

    /// Returns true when the event is consumed.
    func keyDown(_ code: Int, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        let shift = flags.contains(.maskShift)
        if !isActive {
            guard code == KeyCode.tab, flags.contains(.maskCommand),
                  !flags.contains(.maskControl), !flags.contains(.maskAlternate)
            else { return false }
            begin(backward: shift)
            swallowedKeys.insert(code)
            return true
        }
        swallowedKeys.insert(code)
        switch code {
        case KeyCode.tab: move(shift ? -1 : 1)
        case KeyCode.grave, KeyCode.left: move(-1)
        case KeyCode.right: move(1)
        case _ where isRepeat: break
        case KeyCode.escape: end()
        case KeyCode.returnKey, KeyCode.enter: commit(restoreMinimized: flags.contains(.maskAlternate))
        case KeyCode.q: quitSelected()
        case KeyCode.h: entries[selected].app.hide()
        default: break
        }
        return true
    }

    func keyUp(_ code: Int) -> Bool {
        swallowedKeys.remove(code) != nil
    }

    func flagsChanged(_ flags: CGEventFlags) {
        if isActive && !flags.contains(.maskCommand) {
            // As in the built-in switcher, holding ⌥ on release also restores a minimized window.
            commit(restoreMinimized: flags.contains(.maskAlternate))
        }
    }

    private func begin(backward: Bool) {
        entries = tracker.entries(includeWindowless: showsAppsWithoutWindows)
        guard !entries.isEmpty else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if backward {
            selected = entries.count - 1
        } else {
            // The frontmost app comes first; start on the previous one. A frontmost app without windows is not listed.
            selected = entries[0].app.processIdentifier == frontmost && entries.count > 1 ? 1 : 0
        }
        isActive = true
        let show = DispatchWorkItem { [weak self] in
            guard let self, self.isActive else { return }
            self.panel.show(entries: self.entries, selected: self.selected)
        }
        pendingShow = show
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.panelDelay, execute: show)
    }

    private func move(_ delta: Int) {
        select((selected + delta + entries.count) % entries.count)
    }

    private func select(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        selected = index
        panel.select(index)
    }

    private func quitSelected() {
        entries.remove(at: selected).app.terminate()
        guard !entries.isEmpty else { return end() }
        selected = min(selected, entries.count - 1)
        if panel.isVisible {
            panel.show(entries: entries, selected: selected)
        }
    }

    private func commit(restoreMinimized: Bool) {
        guard isActive, entries.indices.contains(selected) else { return end() }
        let entry = entries[selected]
        end()
        if entry.hasWindows {
            activate(entry.app, restoreMinimized: restoreMinimized)
        } else {
            openNewWindow(entry.app)
        }
    }

    private func end() {
        isActive = false
        pendingShow?.cancel()
        pendingShow = nil
        panel.orderOut(nil)
        entries = []
    }

    /// Opening an app that is already running sends it a reopen event, as clicking its Dock icon does;
    /// apps answer it by opening a new window.
    private func openNewWindow(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else {
            return activate(app, restoreMinimized: false)
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error {
                log.error("Reopening \(url.path) failed: \(error.localizedDescription)")
            }
        }
    }

    private func activate(_ app: NSRunningApplication, restoreMinimized: Bool) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        // An app whose windows are all minimized gets all of them restored; with ⌥ held, any app does.
        if restoreMinimized || (!app.isHidden && !WindowScanner.hasWindowOnAnySpace(app.processIdentifier)) {
            WindowScanner.restoreMinimizedWindows(of: element)
        }
        if app.isHidden {
            app.unhide()
        }
        app.activate(options: .activateAllWindows)
        // A background app's activation request can be declined by the system; setting AXFrontmost is not.
        AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
}
