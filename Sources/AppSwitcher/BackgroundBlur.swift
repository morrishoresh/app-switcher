import AppKit

/// Blurs the windows of all apps but the frontmost one, on the desktops it is turned on for: a click-through window per
/// screen, ordered right below the frontmost app's windows that are in front of all other windows, that blurs only
/// where the windows behind are.
final class BackgroundBlur {
    static let radiusRange: ClosedRange<Double> = 2...60
    /// Window order and frames change without notice (new windows, a window of the front app brought forward); checked
    /// this often.
    private static let checkInterval: TimeInterval = 0.25

    /// UUIDs of the desktops (Spaces) to blur on.
    var enabledSpaces: Set<String> = [] {
        didSet {
            if enabledSpaces.isEmpty { stop() } else if timer == nil { start() } else { update() }
        }
    }

    /// Blur radius in points.
    var radius: Double = 20 {
        didSet { applyEffect() }
    }
    /// Also remove the color of the blurred windows.
    var isGrayscale = false {
        didSet { applyEffect() }
    }

    private var windows: [NSWindow] = []
    /// UUID of the display each of `windows` covers.
    private var displays: [String?] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private func start() {
        makeWindows()
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in self?.update() },
            workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.update() },
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                self?.makeWindows()
            },
        ]
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in self?.update() }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0); NotificationCenter.default.removeObserver($0) }
        observers = []
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }

    private func makeWindows() {
        windows.forEach { $0.orderOut(nil) }
        let screens = NSScreen.screens
        windows = screens.map { BlurWindow.make(for: $0, onFullScreenSpaces: false) }
        displays = screens.map(\.displayUUID)
        applyEffect()
        update()
    }

    private func applyEffect() {
        windows.forEach { BlurWindow.setEffect(of: $0, radius: radius, grayscale: isGrayscale) }
    }

    /// Orders the blur windows right below the frontmost app's front windows and limits the blur to the windows behind
    /// them, or hides the blur windows if the app has no window on screen.
    private func update() {
        guard timer != nil, let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != ownPID else { return }
        // On a full-screen Space the blur window is shown over the full-screen window whatever its order, so screens
        // showing one get no blur; nothing behind a full-screen window is visible anyway.
        let current = WindowScanner.currentSpaces()
        var shown: [NSWindow] = []
        for (window, display) in zip(windows, displays) {
            let space = current.spaces.first { $0.display == display || $0.display == WindowScanner.sharedSpacesDisplay }
            if let space, !space.isFullScreen, enabledSpaces.contains(space.space) {
                shown.append(window)
            } else if window.isVisible {
                window.orderOut(nil)
            }
        }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let pid = { (window: [String: Any]) in window[kCGWindowOwnerPID as String] as? pid_t }
        let normal = list.filter { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0 else { return false }
            guard let id = window[kCGWindowNumber as String] as? UInt32 else { return false }
            return pid(window) == ownPID || !current.fullScreenWindows.contains(id)
        }
        // The run of the front app's windows starting at its frontmost one; the blur windows inside it are skipped.
        guard !shown.isEmpty, let first = normal.firstIndex(where: { pid($0) == front }) else {
            shown.forEach { $0.orderOut(nil) }
            return
        }
        var last = first
        for index in normal.indices.dropFirst(first + 1) {
            let owner = pid(normal[index])
            if owner == front { last = index } else if owner != ownPID { break }
        }
        // The desktop is not blurred, only the windows behind the front app's.
        let behind = BlurWindow.appWindowFrames(normal[(last + 1)...])
        shown.forEach { BlurWindow.limit($0, to: behind) }
        let isInPlace = normal.count >= last + 1 + shown.count
            && normal[(last + 1)...].prefix(shown.count).allSatisfy { pid($0) == ownPID }
        guard !isInPlace, let target = normal[last][kCGWindowNumber as String] as? Int else { return }
        for window in shown {
            window.order(.below, relativeTo: target)
        }
    }
}

/// Blurs the app windows on every screen below a given window level, e.g. all apps behind the switcher panel; the
/// desktop is not blurred.
final class ScreenBlur {
    /// Blur radius in points.
    var radius: Double = 20
    /// Also remove the color of the blurred windows.
    var isGrayscale = false
    private var windows: [NSWindow] = []

    func show(below level: NSWindow.Level) {
        hide()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let frames = BlurWindow.appWindowFrames(list)
        windows = NSScreen.screens.map { screen in
            let window = BlurWindow.make(for: screen, onFullScreenSpaces: true)
            window.level = NSWindow.Level(level.rawValue - 1)
            BlurWindow.setEffect(of: window, radius: radius, grayscale: isGrayscale)
            BlurWindow.limit(window, to: frames)
            window.orderFrontRegardless()
            return window
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}

private extension NSScreen {
    /// The display's UUID, as the managed display spaces identify it.
    var displayUUID: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// A click-through window covering a screen that blurs what is behind it, only inside its `BlurMask` rects.
private enum BlurWindow {
    static func make(for screen: NSScreen, onFullScreenSpaces: Bool) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        if onFullScreenSpaces { window.collectionBehavior.insert(.fullScreenAuxiliary) }
        window.contentView = BlurMask(frame: NSRect(origin: .zero, size: screen.frame.size))
        window.setFrame(screen.frame, display: false)
        return window
    }

    static func setEffect(of window: NSWindow, radius: Double, grayscale: Bool) {
        (window.contentView as? BlurMask)?.setEffect(radius: radius, grayscale: grayscale)
    }

    /// Frames, in window-server coordinates, of the app windows in a window list, leaving out AppSwitcher's own
    /// windows, the Dock's (it shows Space switches through windows) and invisible ones.
    static func appWindowFrames<Windows: Sequence>(_ list: Windows) -> [CGRect] where Windows.Element == [String: Any] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        return list.compactMap { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID, pid != dockPID,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary
            else { return nil }
            return CGRect(dictionaryRepresentation: bounds)
        }
    }

    /// Limits the blur of `window` to `frames`, given in window-server coordinates (origin at the top left of the main
    /// display, y down).
    static func limit(_ window: NSWindow, to frames: [CGRect]) {
        guard let mask = window.contentView as? BlurMask, let mainHeight = NSScreen.screens.first?.frame.height else { return }
        let origin = window.frame.origin
        mask.rects = frames
            .map { CGRect(x: $0.minX - origin.x, y: mainHeight - $0.maxY - origin.y, width: $0.width, height: $0.height) }
            .filter { $0.intersects(mask.bounds) }
    }
}

/// Blurs (and optionally grays) what is behind the window, only inside `rects`, through a private Core Animation
/// backdrop layer, as `NSVisualEffectView` does.
private final class BlurMask: NSView {
    /// About the corner radius of windows, so the desktop next to a window's corner is not blurred.
    private static let cornerRadius: CGFloat = 16

    private let backdrop: CALayer? = (NSClassFromString("CABackdropLayer") as? CALayer.Type)?.init()
    private let shape = CAShapeLayer()

    var rects: [NSRect] = [] {
        didSet {
            guard rects != oldValue else { return }
            let path = CGMutablePath()
            for rect in rects {
                path.addRoundedRect(in: rect, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius)
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.path = path
            CATransaction.commit()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        guard let backdrop else {
            log.error("CABackdropLayer is unavailable; nothing is blurred")
            return
        }
        // Samples what the window server draws behind the window, not just this window's content.
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.frame = bounds
        shape.frame = bounds
        backdrop.mask = shape
        layer?.addSublayer(backdrop)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setEffect(radius: Double, grayscale: Bool) {
        var filters = [Self.filter("gaussianBlur", ["inputRadius": radius])]
        if grayscale { filters.append(Self.filter("colorSaturate", ["inputAmount": 0.0])) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.setValue(filters.compactMap { $0 }, forKey: "filters")
        CATransaction.commit()
    }

    /// A private `CAFilter`, the filter type backdrop layers take.
    private static func filter(_ type: String, _ values: [String: Any]) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as AnyObject?,
              let filter = filterClass.perform(NSSelectorFromString("filterWithType:"), with: type)?
                  .takeUnretainedValue() as? NSObject
        else { return nil }
        for (key, value) in values { filter.setValue(value, forKey: key) }
        return filter
    }
}
