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
    /// A ⌘ press shorter than this, with no other key, counts as a tap.
    private static let commandTapMaxDuration: TimeInterval = 0.4
    /// ⌘ pressed again within this time of a tap leaves ⌘⇥ to the built-in switcher until ⌘ is released.
    private static let doubleTapInterval: TimeInterval = 0.35

    /// Also list apps without windows; switching to one opens a new window.
    var showsAppsWithoutWindows = false
    /// Show each app as a snapshot of its front window instead of its icon.
    var showsPreviews = false
    /// List an app's windows one by one instead of the app once.
    var showsEachWindow = true

    private let tracker: AppTracker
    private let panel = SwitcherPanel()
    private var entries: [SwitcherEntry] = []
    private var selected = 0
    private var isActive = false
    private var pendingShow: DispatchWorkItem?
    /// Key-ups are swallowed only for keys whose key-down was swallowed.
    private var swallowedKeys = Set<Int>()
    /// Last snapshot of each listed window; covers windows that cannot be captured now (minimized, hidden).
    private var snapshots: [CGWindowID: CGImage] = [:]
    private var session = 0
    private var isCommandDown = false
    private var commandDownAt = Date.distantPast
    /// Whether a key other than ⌘ was pressed while ⌘ was down, so the press is not a tap.
    private var keyPressedDuringCommand = false
    private var lastCommandTapAt = Date.distantPast
    /// Set for a ⌘ press that follows a ⌘ tap: everything passes through, so ⌘⇥ opens the built-in switcher.
    private var passesThrough = false

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
        keyPressedDuringCommand = true
        if passesThrough { return false }
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
        trackCommandTaps(commandDown: flags.contains(.maskCommand))
        if isActive && !flags.contains(.maskCommand) {
            // As in the built-in switcher, holding ⌥ on release also restores a minimized window.
            commit(restoreMinimized: flags.contains(.maskAlternate))
        }
    }

    /// ⌘ tapped, then pressed again within `doubleTapInterval`: that second press is left to the system.
    private func trackCommandTaps(commandDown: Bool) {
        guard commandDown != isCommandDown else { return }
        isCommandDown = commandDown
        let now = Date()
        if commandDown {
            passesThrough = !isActive && now.timeIntervalSince(lastCommandTapAt) <= Self.doubleTapInterval
            if passesThrough { log.info("⌘ double-tapped: built-in switcher") }
            commandDownAt = now
            keyPressedDuringCommand = false
        } else {
            let isTap = !keyPressedDuringCommand && now.timeIntervalSince(commandDownAt) <= Self.commandTapMaxDuration
            // The pass-through press itself does not start another double tap.
            lastCommandTapAt = isTap && !passesThrough ? now : .distantPast
            passesThrough = false
        }
    }

    private func begin(backward: Bool) {
        if showsEachWindow { tracker.noteFrontmostWindow() }
        entries = tracker.entries(includeWindowless: showsAppsWithoutWindows, eachWindow: showsEachWindow)
        guard !entries.isEmpty else { return }
        session += 1
        let listed = Set(entries.compactMap(\.previewWindow))
        snapshots = snapshots.filter { listed.contains($0.key) }
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
        let app = entries[selected].app
        app.terminate()
        // With each window listed, the app's other windows go too.
        entries.removeAll { $0.app.processIdentifier == app.processIdentifier }
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
        // Windows on no Space (minimized, hidden) cannot be captured; they keep their last snapshot.
        let ids = Set(entries.compactMap { entry in entry.window.map { $0.isOnSpace ? $0.id : nil } ?? entry.previewWindow })
        let scale = panel.screen?.backingScaleFactor ?? 2
        Task { @MainActor [weak self] in
            let images = await Thumbnailer.capture(ids: ids, maxSize: SwitcherPanel.previewSize, scale: scale)
            guard let self else { return }
            for (id, image) in images {
                self.snapshots[id] = image
                if self.isActive, current == self.session { self.panel.setSnapshot(image, forWindow: id) }
            }
        }
    }

    private func commit(restoreMinimized: Bool) {
        guard isActive, entries.indices.contains(selected) else { return end() }
        let entry = entries[selected]
        end()
        if let window = entry.window {
            AppWindows.focus(window, of: entry.app)
        } else if entry.hasWindows {
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
