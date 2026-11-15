import AppKit

/// Shows the windows and tabs of the app whose Dock icon the pointer rests on.
final class DockPreviewController {
    /// Sweeping the pointer across the Dock shows nothing; resting on an icon this long does.
    private static let showDelay: TimeInterval = 0.4
    /// Time to move the pointer between the icon and the panel before the panel closes.
    private static let hideDelay: TimeInterval = 0.3
    private static let pointerCheckInterval: TimeInterval = 0.15
    /// Margin around the icon that still counts as on it, for the pointer resting on its edge.
    private static let iconSlack: CGFloat = 6
    private static let thumbnailCacheLimit = 200
    /// Pointer rest on a tab title before that tab is selected, so passing over titles selects nothing.
    private static let tabHoverDelay: TimeInterval = 0.15
    /// Time for the app to draw a newly selected tab before it is captured.
    private static let tabDrawDelay: TimeInterval = 0.3

    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? attachIfReady() : detach()
        }
    }

    private let dock = DockObserver()
    private let panel = DockPreviewPanel()
    private var accessibilityGranted = false
    private var isAttached = false
    private var hovered: DockItem?
    private var shown: (app: NSRunningApplication, windows: [WindowInfo])?
    /// After a click on the icon, its preview stays closed until the pointer moves to another icon.
    private var suppressedPid: pid_t?
    private var pendingShow: DispatchWorkItem?
    private var pointerTimer: Timer?
    private var pointerLeftAt: Date?
    private var clickMonitor: Any?
    private var generation = 0
    /// Last snapshot of each window; covers windows that cannot be captured now (minimized, other Space).
    private var thumbnails: [CGWindowID: CGImage] = [:]
    /// Last snapshot of each tab, taken while it was selected.
    private var tabSnapshots: [AXUIElement: CGImage] = [:]
    /// Tab selected in each window before hovering selected another; restored when the preview closes without a click.
    private var originalTabs: [CGWindowID: AXUIElement] = [:]
    /// Tab currently selected by hovering, per window.
    private var hoverSelectedTabs: [CGWindowID: AXUIElement] = [:]
    private var pendingTabSelect: DispatchWorkItem?

    init() {
        dock.onChange = { [weak self] in self?.hoverChanged($0) }
        panel.onWindowClick = { [weak self] in self?.focus(window: $0, tab: nil) }
        panel.onTabClick = { [weak self] in self?.focus(window: $0, tab: $1) }
        panel.onTabHover = { [weak self] in self?.tabHovered(window: $0, tab: $1) }
    }

    /// Call once Accessibility access is granted; observing the Dock needs it.
    func accessibilityDidBecomeAvailable() {
        accessibilityGranted = true
        attachIfReady()
    }

    private func attachIfReady() {
        guard isEnabled, accessibilityGranted, !isAttached else { return }
        // A Dock that is not running yet is attached to once it launches.
        if !dock.start() { log.error("Dock not found; previews start once it launches") }
        isAttached = true
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.clickedOutside()
        }
    }

    private func detach() {
        dock.stop()
        isAttached = false
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        hide()
    }

    private func hoverChanged(_ item: DockItem?) {
        hovered = item
        if item?.app.processIdentifier != suppressedPid { suppressedPid = nil }
        pendingShow?.cancel()
        pendingShow = nil
        guard let item, suppressedPid == nil else { return }
        if panel.isVisible {
            if shown?.app.processIdentifier != item.app.processIdentifier { load(item) }
            return
        }
        let show = DispatchWorkItem { [weak self] in self?.load(item) }
        pendingShow = show
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.showDelay, execute: show)
    }

    /// Lists the windows off the main thread (Accessibility calls can block), then shows the panel and fills in snapshots.
    private func load(_ item: DockItem) {
        // Moving to another app's icon closes the previous app's preview.
        pendingTabSelect?.cancel()
        restoreTabs()
        generation += 1
        let current = generation
        let app = item.app
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let windows = AppWindows.windows(of: app)
            DispatchQueue.main.async {
                guard let self, current == self.generation,
                      self.hovered?.app.processIdentifier == app.processIdentifier else { return }
                guard !windows.isEmpty else { return self.hide() }
                self.shown = (app, windows)
                // The icon may have moved since it was hovered, for one while the Dock was still sliding in.
                let iconFrame = self.dock.currentItem().flatMap { $0.app == app ? $0.frame : nil } ?? item.frame
                self.panel.show(app: app, windows: windows, thumbnails: self.thumbnails, beside: iconFrame)
                self.startPointerChecks()
                self.captureThumbnails(of: windows, generation: current)
            }
        }
    }

    private func captureThumbnails(of windows: [WindowInfo], generation current: Int) {
        let scale = panel.screen?.backingScaleFactor ?? 2
        Task { @MainActor [weak self] in
            let images = await Thumbnailer.capture(windows, maxSize: DockPreviewPanel.thumbnailSize, scale: scale)
            guard let self, !images.isEmpty else { return }
            if self.thumbnails.count + images.count > Self.thumbnailCacheLimit { self.thumbnails.removeAll() }
            self.thumbnails.merge(images) { _, new in new }
            if self.tabSnapshots.count + images.count > Self.thumbnailCacheLimit { self.tabSnapshots.removeAll() }
            for window in windows {
                if let image = images[window.id], let tab = window.tabs.first(where: \.isSelected) {
                    self.tabSnapshots[tab.element] = image
                }
            }
            if current == self.generation, self.panel.isVisible { self.panel.setThumbnails(images) }
        }
    }

    /// Background tabs are not drawn, so a tab's content can only be captured once it is selected. Resting on a tab
    /// title selects that tab in the app and captures the window; until then the tab's last snapshot, if any, shows.
    private func tabHovered(window index: Int, tab tabIndex: Int) {
        pendingTabSelect?.cancel()
        guard let shown, shown.windows.indices.contains(index) else { return }
        let window = shown.windows[index]
        guard window.isOnSpace, window.tabs.indices.contains(tabIndex) else { return }
        let tab = window.tabs[tabIndex]
        if let cached = tabSnapshots[tab.element] { panel.setThumbnails([window.id: cached]) }
        let select = DispatchWorkItem { [weak self] in self?.selectTab(tab, in: window) }
        pendingTabSelect = select
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tabHoverDelay, execute: select)
    }

    private func selectTab(_ tab: TabInfo, in window: WindowInfo) {
        let selected = hoverSelectedTabs[window.id] ?? window.tabs.first(where: \.isSelected)?.element
        if selected != tab.element {
            if originalTabs[window.id] == nil, let selected { originalTabs[window.id] = selected }
            AXUIElementPerformAction(tab.element, kAXPressAction as CFString)
            hoverSelectedTabs[window.id] = tab.element
        }
        let current = generation
        let scale = panel.screen?.backingScaleFactor ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.tabDrawDelay) { [weak self] in
            guard let self, current == self.generation else { return }
            Task { @MainActor [weak self] in
                let images = await Thumbnailer.capture(ids: [window.id], maxSize: DockPreviewPanel.thumbnailSize, scale: scale)
                guard let self, let image = images[window.id] else { return }
                self.tabSnapshots[tab.element] = image
                let showing = self.hoverSelectedTabs[window.id] ?? window.tabs.first(where: \.isSelected)?.element
                if current == self.generation, showing == tab.element { self.panel.setThumbnails([window.id: image]) }
            }
        }
    }

    /// Puts back the tabs that hovering selected, except in `kept`, the window just clicked.
    private func restoreTabs(except kept: CGWindowID? = nil) {
        for (id, original) in originalTabs where id != kept && hoverSelectedTabs[id] != original {
            AXUIElementPerformAction(original, kAXPressAction as CFString)
        }
        originalTabs = [:]
        hoverSelectedTabs = [:]
    }

    /// The Dock does not always report the pointer leaving an icon, for one when it hides itself. So while the panel is
    /// up, the pointer is checked directly: it closes once the pointer has been off both the panel and the icon the Dock
    /// currently has under it for `hideDelay`.
    private func startPointerChecks() {
        pointerLeftAt = nil
        guard pointerTimer == nil else { return }
        pointerTimer = Timer.scheduledTimer(withTimeInterval: Self.pointerCheckInterval, repeats: true) { [weak self] _ in
            self?.checkPointer()
        }
    }

    private func checkPointer() {
        let mouse = NSEvent.mouseLocation
        let item = dock.currentItem()
        if let item, item.app == shown?.app {
            panel.move(beside: item.frame)
        }
        let onIcon = item.map {
            NSMouseInRect(mouse, $0.frame.insetBy(dx: -Self.iconSlack, dy: -Self.iconSlack), false)
        } ?? false
        if onIcon || NSMouseInRect(mouse, panel.frame, false) {
            pointerLeftAt = nil
        } else if let left = pointerLeftAt {
            if Date().timeIntervalSince(left) >= Self.hideDelay { hide() }
        } else {
            pointerLeftAt = Date()
        }
    }

    private func hide(keepingTabsOf kept: CGWindowID? = nil) {
        generation += 1
        pendingShow?.cancel()
        pendingShow = nil
        pendingTabSelect?.cancel()
        pendingTabSelect = nil
        restoreTabs(except: kept)
        pointerTimer?.invalidate()
        pointerTimer = nil
        shown = nil
        panel.orderOut(nil)
    }

    /// Clicks in the panel are not seen here; any other click closes it. A click on the hovered icon keeps it closed.
    private func clickedOutside() {
        suppressedPid = hovered?.app.processIdentifier
        hide()
    }

    private func focus(window index: Int, tab: Int?) {
        guard let shown, shown.windows.indices.contains(index) else { return }
        let window = shown.windows[index]
        hide(keepingTabsOf: window.id)
        suppressedPid = hovered?.app.processIdentifier
        AppWindows.focus(window, of: shown.app, tab: tab.flatMap { window.tabs.indices.contains($0) ? window.tabs[$0] : nil })
    }
}
