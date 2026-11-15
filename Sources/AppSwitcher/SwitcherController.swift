import AppKit

private enum KeyCode {
    static let tab = 48
    static let grave = 50
    static let escape = 53
    static let returnKey = 36
    static let enter = 76
    static let left = 123
    static let right = 124
    static let down = 125
    static let up = 126
    static let q = 12
    static let h = 4
}

/// The ⌘⇥ session: starts on ⌘⇥, cycles while ⌘ is held, switches on ⌘ release.
final class SwitcherController {
    /// Quick ⌘⇥ taps switch without flashing the panel.
    private static let panelDelay: TimeInterval = 0.12

    /// Also list apps without windows; switching to one opens a new window.
    var showsAppsWithoutWindows = false
    /// Show each app as a snapshot of its front window instead of its icon.
    var showsPreviews = false

    private let tracker: AppTracker
    private let panel = SwitcherPanel()
    private var entries: [SwitcherEntry] = []
    private var selected = 0
    private var isActive = false
    private var pendingShow: DispatchWorkItem?
    /// Key-ups are swallowed only for keys whose key-down was swallowed.
    private var swallowedKeys = Set<Int>()
    /// Last snapshot of each app's front window; covers apps whose windows cannot be captured now (minimized, hidden).
    private var snapshots: [pid_t: CGImage] = [:]
    private var session = 0

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
        case KeyCode.up: moveRow(-1)
        case KeyCode.down: moveRow(1)
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
        session += 1
        let running = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        snapshots = snapshots.filter { running.contains($0.key) }
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
            self.showPanel()
            if self.showsPreviews { self.captureSnapshots(session: self.session) }
        }
        pendingShow = show
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.panelDelay, execute: show)
    }

    private func move(_ delta: Int) {
        select((selected + delta + entries.count) % entries.count)
    }

    /// Same position in the row above or below; nothing past the first or last row.
    private func moveRow(_ delta: Int) {
        let target = selected + delta * panel.columns
        if entries.indices.contains(target) { select(target) }
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
            showPanel()
        }
    }

    private func showPanel() {
        panel.show(entries: entries, selected: selected, snapshots: showsPreviews ? snapshots : nil)
    }

    /// Captures each listed app's front window and fills the snapshots in as they arrive.
    private func captureSnapshots(session current: Int) {
        let front = WindowScanner.frontWindows()
        var pidByWindow: [CGWindowID: pid_t] = [:]
        for entry in entries {
            if let id = front[entry.app.processIdentifier] { pidByWindow[id] = entry.app.processIdentifier }
        }
        let scale = panel.screen?.backingScaleFactor ?? 2
        Task { @MainActor [weak self] in
            let images = await Thumbnailer.capture(ids: Set(pidByWindow.keys), maxSize: SwitcherPanel.previewSize, scale: scale)
            guard let self else { return }
            for (id, image) in images {
                guard let pid = pidByWindow[id] else { continue }
                self.snapshots[pid] = image
                if self.isActive, current == self.session { self.panel.setSnapshot(image, for: pid) }
            }
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
