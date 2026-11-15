import AppKit

/// Cards for one app's windows, each with a snapshot, the title and the window's tabs, placed next to its Dock icon.
final class DockPreviewPanel: NSPanel {
    var onWindowClick: ((Int) -> Void)?
    var onTabClick: ((_ window: Int, _ tab: Int) -> Void)?
    var onTabHover: ((_ window: Int, _ tab: Int) -> Void)?
    var onWindowClose: ((Int) -> Void)?
    var onTabClose: ((_ window: Int, _ tab: Int) -> Void)?

    /// Set from the menu-bar menu.
    static var thumbnailSize = CGSize(width: 220, height: 138)
    private static let margin: CGFloat = 10
    private static let spacing: CGFloat = 8
    private static let headerHeight: CGFloat = 22
    private static let dockGap: CGFloat = 6
    private static let cornerRadius: CGFloat = 16

    private let background = NSVisualEffectView()
    private let header = NSTextField(labelWithString: "")
    private var cards: [CardView] = []
    private var windowIDs: [CGWindowID] = []
    /// Frame of the icon the panel is placed beside.
    private var anchor = NSRect.zero

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = SwitcherPanel.roundedMask(radius: Self.cornerRadius)
        contentView = background

        header.font = .systemFont(ofSize: 12, weight: .semibold)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        background.addSubview(header)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(app: NSRunningApplication, windows: [WindowInfo], thumbnails: [CGWindowID: CGImage], beside item: NSRect) {
        let screen = Self.screen(containing: item)
        let visible = screen.visibleFrame
        let m = Self.margin, s = Self.spacing
        let cardSize = CardView.size(for: windows)
        let maxColumns = max(1, Int((visible.width * 0.9 - 2 * m + s) / (cardSize.width + s)))
        let maxRows = max(1, Int((visible.height * 0.8 - Self.headerHeight - 2 * m + s) / (cardSize.height + s)))
        let shown = Array(windows.prefix(maxColumns * maxRows))
        let columns = min(shown.count, maxColumns)
        let rows = (shown.count + columns - 1) / columns
        let size = NSSize(width: 2 * m + CGFloat(columns) * cardSize.width + CGFloat(columns - 1) * s,
                          height: 2 * m + Self.headerHeight + CGFloat(rows) * cardSize.height + CGFloat(rows - 1) * s)

        let appName = app.localizedName ?? ""
        header.stringValue = windows.count > shown.count ? "\(appName) – \(shown.count) of \(windows.count) windows" : appName
        header.frame = NSRect(x: m + 4, y: size.height - m - Self.headerHeight + 2, width: size.width - 2 * m - 8, height: 16)

        cards.forEach { $0.removeFromSuperview() }
        cards = shown.enumerated().map { index, window in
            let column = index % columns, row = index / columns
            let origin = NSPoint(x: m + CGFloat(column) * (cardSize.width + s),
                                 y: size.height - m - Self.headerHeight - CGFloat(row + 1) * cardSize.height - CGFloat(row) * s)
            let card = CardView(frame: NSRect(origin: origin, size: cardSize), window: window,
                                fallbackTitle: appName, icon: app.icon)
            card.onClick = { [weak self] in self?.onWindowClick?(index) }
            card.onTabClick = { [weak self] in self?.onTabClick?(index, $0) }
            card.onTabHover = { [weak self] in self?.onTabHover?(index, $0) }
            card.onClose = { [weak self] in self?.onWindowClose?(index) }
            card.onTabClose = { [weak self] in self?.onTabClose?(index, $0) }
            background.addSubview(card)
            return card
        }
        windowIDs = shown.map(\.id)
        setThumbnails(thumbnails)

        anchor = item
        setFrame(NSRect(origin: Self.origin(for: size, beside: item, in: screen), size: size), display: true)
        orderFrontRegardless()
    }

    /// Follows the icon when it moves: the Dock slides in when shown and icons grow with magnification.
    func move(beside item: NSRect) {
        guard isVisible, item != anchor else { return }
        anchor = item
        setFrameOrigin(Self.origin(for: frame.size, beside: item, in: Self.screen(containing: item)))
    }

    private static func screen(containing item: NSRect) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(NSPoint(x: item.midX, y: item.midY), $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func setThumbnails(_ thumbnails: [CGWindowID: CGImage]) {
        for (card, id) in zip(cards, windowIDs) {
            if let image = thumbnails[id] { card.setThumbnail(image) }
        }
    }

    /// Beside the icon on the side facing away from the screen edge the Dock is on, kept within the screen.
    private static func origin(for size: NSSize, beside item: NSRect, in screen: NSScreen) -> NSPoint {
        let full = screen.frame, visible = screen.visibleFrame
        let inset: CGFloat = 4
        let toLeft = item.midX - full.minX, toRight = full.maxX - item.midX, toBottom = item.midY - full.minY
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, visible.minX + inset), visible.maxX - inset - size.width) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, visible.minY + inset), visible.maxY - inset - size.height) }
        if toBottom <= min(toLeft, toRight) {
            return NSPoint(x: clampX(item.midX - size.width / 2), y: item.maxY + dockGap)
        } else if toLeft < toRight {
            return NSPoint(x: item.maxX + dockGap, y: clampY(item.midY - size.height / 2))
        } else {
            return NSPoint(x: item.minX - dockGap - size.width, y: clampY(item.midY - size.height / 2))
        }
    }
}

/// Highlights while the pointer is on it and reports clicks.
private class HoverView: NSView {
    var onClick: (() -> Void)?
    var cornerRadius: CGFloat = 8
    /// Shown only while the pointer is on this view, such as its close button.
    var revealedOnHover: NSView? {
        didSet { revealedOnHover?.isHidden = !isHovered }
    }
    private(set) var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            revealedOnHover?.isHidden = !isHovered
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isHovered else { return }
        NSColor.labelColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    /// Labels and images inside take no clicks; the innermost hover view gets them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is HoverView ? hit : self
    }

    var onEnter: (() -> Void)?

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onEnter?()
    }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class CardView: HoverView {
    var onTabClick: ((Int) -> Void)?
    var onTabHover: ((Int) -> Void)?
    var onClose: (() -> Void)?
    var onTabClose: ((Int) -> Void)?

    private static let padding: CGFloat = 6
    private static let titleHeight: CGFloat = 18
    private static let tabHeight: CGFloat = 20
    private static let maxTabRows = 8
    private static let iconSize: CGFloat = 56

    private let imageView = NSImageView()

    /// Cards share one size: the tallest one sets the height.
    static func size(for windows: [WindowInfo]) -> NSSize {
        let thumbnail = DockPreviewPanel.thumbnailSize
        let below = windows.map { window -> CGFloat in
            let rows = min(window.tabs.count, maxTabRows)
            return (showsTitle(window) ? 4 + titleHeight : 0) + (rows > 0 ? 4 + CGFloat(rows) * tabHeight : 0)
        }.max() ?? 0
        return NSSize(width: thumbnail.width + 2 * padding, height: 2 * padding + thumbnail.height + below)
    }

    /// A window with tabs is titled after its selected tab, which the tab list already shows; only "Minimized" is added.
    private static func showsTitle(_ window: WindowInfo) -> Bool {
        window.tabs.isEmpty || window.isMinimized
    }

    init(frame: NSRect, window: WindowInfo, fallbackTitle: String, icon: NSImage?) {
        super.init(frame: frame)
        let p = Self.padding
        let thumbnail = DockPreviewPanel.thumbnailSize
        let thumbnailTop = frame.height - p

        // Until a snapshot arrives, and for windows that cannot be captured: the app icon, faded.
        imageView.image = icon
        imageView.alphaValue = 0.5
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(x: p + (thumbnail.width - Self.iconSize) / 2, y: thumbnailTop - (thumbnail.height + Self.iconSize) / 2,
                                 width: Self.iconSize, height: Self.iconSize)
        imageView.unregisterDraggedTypes()
        addSubview(imageView)

        var rowTop = thumbnailTop - thumbnail.height
        if Self.showsTitle(window) {
            let name = window.title.isEmpty ? fallbackTitle : window.title
            let text = window.tabs.isEmpty ? (window.isMinimized ? "\(name) (minimized)" : name) : "Minimized"
            let title = NSTextField(labelWithString: text)
            title.font = .systemFont(ofSize: 12, weight: .medium)
            title.textColor = window.isMinimized ? .secondaryLabelColor : .labelColor
            title.lineBreakMode = .byTruncatingTail
            title.frame = NSRect(x: p + 2, y: rowTop - 4 - Self.titleHeight, width: thumbnail.width - 4, height: Self.titleHeight)
            addSubview(title)
            rowTop -= 4 + Self.titleHeight
        }
        rowTop -= 4
        let overflow = window.tabs.count > Self.maxTabRows
        let listed = overflow ? Self.maxTabRows - 1 : window.tabs.count
        for (index, tab) in window.tabs.prefix(listed).enumerated() {
            let row = TabRowView(frame: NSRect(x: p, y: rowTop - Self.tabHeight, width: thumbnail.width, height: Self.tabHeight),
                                 title: tab.title, isSelected: tab.isSelected)
            row.onClick = { [weak self] in self?.onTabClick?(index) }
            row.onEnter = { [weak self] in self?.onTabHover?(index) }
            row.onClose = { [weak self] in self?.onTabClose?(index) }
            addSubview(row)
            rowTop -= Self.tabHeight
        }
        if overflow {
            let more = NSTextField(labelWithString: "+\(window.tabs.count - listed) more tabs")
            more.font = .systemFont(ofSize: 11)
            more.textColor = .tertiaryLabelColor
            more.frame = NSRect(x: p + 16, y: rowTop - Self.tabHeight + 3, width: thumbnail.width - 20, height: 15)
            addSubview(more)
        }

        // Added last, so it is on top of the snapshot.
        // Top left, where the system puts it in a window.
        let close = CloseButton(frame: NSRect(x: 8, y: frame.height - 8 - CloseButton.size,
                                              width: CloseButton.size, height: CloseButton.size))
        close.onClick = { [weak self] in self?.onClose?() }
        addSubview(close)
        revealedOnHover = close
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setThumbnail(_ image: CGImage) {
        let thumbnail = DockPreviewPanel.thumbnailSize
        let p = Self.padding
        let fit = min(thumbnail.width / CGFloat(image.width), thumbnail.height / CGFloat(image.height))
        let size = NSSize(width: CGFloat(image.width) * fit, height: CGFloat(image.height) * fit)
        imageView.image = NSImage(cgImage: image, size: size)
        imageView.alphaValue = 1
        imageView.frame = NSRect(x: p + (thumbnail.width - size.width) / 2,
                                 y: bounds.height - p - thumbnail.height + (thumbnail.height - size.height) / 2,
                                 width: size.width, height: size.height)
    }
}

private final class TabRowView: HoverView {
    var onClose: (() -> Void)?

    init(frame: NSRect, title: String, isSelected: Bool) {
        super.init(frame: frame)
        cornerRadius = 5
        let marker = NSTextField(labelWithString: isSelected ? "•" : "")
        marker.font = .systemFont(ofSize: 12, weight: .bold)
        marker.frame = NSRect(x: 4, y: 2, width: 10, height: 16)
        addSubview(marker)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular)
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 16, y: 2, width: frame.width - 22 - CloseButton.size, height: 16)
        addSubview(label)
        let size = CloseButton.size
        let close = CloseButton(frame: NSRect(x: frame.width - 3 - size, y: (frame.height - size) / 2, width: size, height: size))
        close.onClick = { [weak self] in self?.onClose?() }
        addSubview(close)
        revealedOnHover = close
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// The system window close button, so it follows the current appearance. It draws its active, hovered look (× on red)
/// only while the pointer is reported to be over its button group, which `_mouseInGroup:` on its superview answers.
/// Clicks are taken here rather than by the button, since the panel never becomes key.
private final class CloseButton: HoverView {
    static let size: CGFloat = 14

    private let button = NSWindow.standardWindowButton(.closeButton, for: [.titled, .closable])

    override init(frame: NSRect) {
        super.init(frame: frame)
        if let button {
            button.frame = NSRect(x: (frame.width - button.frame.width) / 2, y: (frame.height - button.frame.height) / 2,
                                  width: button.frame.width, height: button.frame.height)
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    @objc func _mouseInGroup(_ button: NSButton) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func draw(_ dirtyRect: NSRect) {
        guard button == nil else { return }
        // Without the system button: a red circle with a dark ×.
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
        let arm = bounds.width * 0.2
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: bounds.midX - arm, y: bounds.midY - arm))
        cross.line(to: NSPoint(x: bounds.midX + arm, y: bounds.midY + arm))
        cross.move(to: NSPoint(x: bounds.midX - arm, y: bounds.midY + arm))
        cross.line(to: NSPoint(x: bounds.midX + arm, y: bounds.midY - arm))
        cross.lineWidth = 1.5
        NSColor.black.withAlphaComponent(0.6).setStroke()
        cross.stroke()
    }
}
