import AppKit

/// Row of app icons with the selected app's name underneath, centered on the screen with the pointer.
final class SwitcherPanel: NSPanel {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    private static let margin: CGFloat = 16
    private static let labelHeight: CGFloat = 26
    private static let maxIconSize: CGFloat = 96
    private static let minIconSize: CGFloat = 24
    private static let iconInset: CGFloat = 10
    private static let cornerRadius: CGFloat = 20

    private let background = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private var items: [ItemView] = []
    private var names: [String] = []
    private var hasWindows: [Bool] = []

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
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        contentView = background

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        background.addSubview(label)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(entries: [SwitcherEntry], selected: Int) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let m = Self.margin
        let available = visible.width * 0.9 - 2 * m
        let iconSize = max(Self.minIconSize, min(Self.maxIconSize, available / CGFloat(entries.count) - 2 * Self.iconInset))
        let cell = iconSize + 2 * Self.iconInset
        let size = NSSize(width: 2 * m + cell * CGFloat(entries.count), height: 2 * m + cell + Self.labelHeight)

        items.forEach { $0.removeFromSuperview() }
        items = entries.enumerated().map { index, entry in
            let frame = NSRect(x: m + CGFloat(index) * cell, y: m + Self.labelHeight, width: cell, height: cell)
            let item = ItemView(frame: frame, icon: entry.app.icon, dimmed: !entry.hasWindows, inset: Self.iconInset, index: index)
            item.onHover = { [weak self] in self?.onHover?($0) }
            item.onClick = { [weak self] in self?.onClick?($0) }
            background.addSubview(item)
            return item
        }
        names = entries.map { $0.app.localizedName ?? "" }
        hasWindows = entries.map(\.hasWindows)

        setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                        width: size.width, height: size.height), display: false)
        select(selected)
        orderFrontRegardless()
    }

    func select(_ index: Int) {
        for (i, item) in items.enumerated() {
            item.isSelected = i == index
        }
        guard items.indices.contains(index) else { return }
        let m = Self.margin
        label.stringValue = hasWindows[index] ? names[index] : "\(names[index]) – New Window"
        label.textColor = hasWindows[index] ? .labelColor : .secondaryLabelColor
        label.sizeToFit()
        let width = min(label.frame.width + 8, frame.width - 2 * m)
        let x = min(max(items[index].frame.midX - width / 2, m), frame.width - m - width)
        let y = m + (Self.labelHeight - label.frame.height) / 2
        label.frame = NSRect(x: x, y: y, width: width, height: label.frame.height)
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

private final class ItemView: NSView {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?
    var isSelected = false {
        didSet { if isSelected != oldValue { needsDisplay = true } }
    }

    private let icon: NSImage?
    private let dimmed: Bool
    private let inset: CGFloat
    private let index: Int

    init(frame: NSRect, icon: NSImage?, dimmed: Bool, inset: CGFloat, index: Int) {
        self.icon = icon
        self.dimmed = dimmed
        self.inset = inset
        self.index = index
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.labelColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
        }
        // Apps without windows: faded and slightly smaller.
        let iconRect = bounds.insetBy(dx: dimmed ? inset * 1.6 : inset, dy: dimmed ? inset * 1.6 : inset)
        icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.4 : 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Selection follows the pointer only once it moves, so a pointer resting where the panel appears changes nothing.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { onHover?(index) }
    override func mouseDown(with event: NSEvent) { onClick?(index) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
