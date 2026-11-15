import AppKit

struct SwitcherEntry {
    let app: NSRunningApplication
    let hasWindows: Bool
    /// The one window this entry stands for, when each window is listed separately.
    var window: WindowInfo? = nil
    /// The window whose snapshot shows this entry.
    var previewWindow: CGWindowID? = nil
}

/// Keeps running apps, and windows, in most-recently-activated order, like the built-in switcher.
final class AppTracker {
    private static let recentWindowsLimit = 200
    private var recent: [pid_t] = []
    /// Windows by when they were last focused, as seen on app activation and when a switch begins; windows focused
    /// within an app (⌘`, a click) are seen only at the next of those.
    private var recentWindows: [CGWindowID] = []

    func start() {
        seed()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.moveToFront(app.processIdentifier)
            self?.recordFocusedWindow(of: app.processIdentifier)
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.recent.removeAll { $0 == app.processIdentifier }
        }
    }

    /// The frontmost app's focused window is the most recent one; call when a switch begins.
    func noteFrontmostWindow() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let id = AppWindows.focusedWindowID(of: pid) else { return }
        moveWindowToFront(id)
    }

    /// Regular apps, most recently used first: those with at least one window, plus the rest if `includeWindowless`.
    /// With `eachWindow`, an app's windows are listed one by one instead, most recently focused first; windows never
    /// seen focused follow, by app recency and then front to back.
    func entries(includeWindowless: Bool, eachWindow: Bool) -> [SwitcherEntry] {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications.enumerated().filter {
            $0.element.activationPolicy == .regular && !$0.element.isTerminated && $0.element.processIdentifier != ownPid
        }
        // Apps never activated since launch keep their launch order after the recently used ones.
        let ordered = running.sorted {
            let a = recent.firstIndex(of: $0.element.processIdentifier) ?? Int.max
            let b = recent.firstIndex(of: $1.element.processIdentifier) ?? Int.max
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
        let spaceWindows = WindowScanner.windowsInSpaces()
        guard eachWindow else {
            let front = WindowScanner.frontWindows(in: spaceWindows)
            let withWindows = WindowScanner.pidsWithWindows(among: ordered.map(\.processIdentifier), spaceWindows: spaceWindows)
            return ordered.compactMap { app in
                let hasWindows = withWindows.contains(app.processIdentifier)
                return hasWindows || includeWindowless
                    ? SwitcherEntry(app: app, hasWindows: hasWindows, previewWindow: front[app.processIdentifier]) : nil
            }
        }

        var lists = [[WindowInfo]](repeating: [], count: ordered.count)
        lists.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: ordered.count) { i in
                buffer[i] = AppWindows.windows(of: ordered[i], spaceWindows: spaceWindows, includeTabs: false)
            }
        }
        var ranked: [(entry: SwitcherEntry, recency: Int, app: Int, order: Int)] = []
        for (appRank, (app, windows)) in zip(ordered, lists).enumerated() {
            if windows.isEmpty {
                if includeWindowless { ranked.append((SwitcherEntry(app: app, hasWindows: false), .max, appRank, 0)) }
                continue
            }
            for (order, window) in windows.enumerated() {
                let entry = SwitcherEntry(app: app, hasWindows: true, window: window, previewWindow: window.id)
                ranked.append((entry, recentWindows.firstIndex(of: window.id) ?? .max, appRank, order))
            }
        }
        return ranked.sorted { ($0.recency, $0.app, $0.order) < ($1.recency, $1.app, $1.order) }.map(\.entry)
    }

    /// The focused window of an app that just activated, looked up off the main thread.
    private func recordFocusedWindow(of pid: pid_t) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let id = AppWindows.focusedWindowID(of: pid) else { return }
            DispatchQueue.main.async { self?.moveWindowToFront(id) }
        }
    }

    private func moveWindowToFront(_ id: CGWindowID) {
        recentWindows.removeAll { $0 == id }
        recentWindows.insert(id, at: 0)
        if recentWindows.count > Self.recentWindowsLimit { recentWindows.removeLast() }
    }

    private func moveToFront(_ pid: pid_t) {
        recent.removeAll { $0 == pid }
        recent.insert(pid, at: 0)
    }

    /// Before any activation is observed, approximate recency from the front-to-back order of on-screen windows.
    private func seed() {
        var order: [pid_t] = []
        if let front = NSWorkspace.shared.frontmostApplication {
            order.append(front.processIdentifier)
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where (window[kCGWindowLayer as String] as? Int) == 0 {
            if let pid = window[kCGWindowOwnerPID as String] as? pid_t, !order.contains(pid) {
                order.append(pid)
            }
        }
        recent = order
    }
}
