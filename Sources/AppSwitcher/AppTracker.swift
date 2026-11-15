import AppKit

struct SwitcherEntry {
    let app: NSRunningApplication
    let hasWindows: Bool
}

/// Keeps running apps in most-recently-activated order, like the built-in switcher.
final class AppTracker {
    private var recent: [pid_t] = []

    func start() {
        seed()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.moveToFront(app.processIdentifier)
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.recent.removeAll { $0 == app.processIdentifier }
        }
    }

    /// Regular apps, most recently used first: those with at least one window, plus the rest if `includeWindowless`.
    func entries(includeWindowless: Bool) -> [SwitcherEntry] {
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
        let withWindows = WindowScanner.pidsWithWindows(among: ordered.map(\.processIdentifier))
        return ordered.compactMap { app in
            let hasWindows = withWindows.contains(app.processIdentifier)
            return hasWindows || includeWindowless ? SwitcherEntry(app: app, hasWindows: hasWindows) : nil
        }
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
