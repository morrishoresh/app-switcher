import AppKit

/// Row of apps with the selected app's name underneath, centered on the screen with the pointer. Each app is its icon,
/// or with previews on, a snapshot of its front window badged with its icon, the selected one larger than the rest.
final class SwitcherPanel: NSPanel {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    private static let margin: CGFloat = 16
    private static let labelHeight: CGFloat = 26
    /// Icon size of the built-in ⌘⇥ switcher. Icons and the previews of not-selected apps never get smaller; apps
    /// wrap onto another row instead.
    private static let standardIconSize: CGFloat = 128
    private static let iconInset: CGFloat = 10
    private static let cornerRadius: CGFloat = 20
    /// Snapshot size of the selected app; the others are `previewScale` of it. Set from the menu-bar menu.
    static var previewSize = CGSize(width: 320, height: 200)
    static var previewScale: CGFloat = 0.6
    /// Most apps per row; 0 for as many as fit. Set from the menu-bar menu.
    static var appsPerRow = 0
    /// Largest share of the row the selected app's preview takes.
    private static let maxSelectedShare: CGFloat = 0.5

    private let background = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private var items: [ItemView] = []
    private var names: [String] = []
    private var hasWindows: [Bool] = []
    private var pids: [pid_t] = []
    /// Cell sizes in preview mode: the selected app's and the others'.
    private var largeCell = NSSize.zero
    private var smallCell = NSSize.zero
    private var showsPreviews = false
    /// Apps per row in the current layout.
    private(set) var columns = 1
    private var rows = 1

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

    /// With `snapshots` (keyed by pid), apps are shown as previews; apps without a snapshot yet show their icon.
    func show(entries: [SwitcherEntry], selected: Int, snapshots: [pid_t: CGImage]? = nil) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let m = Self.margin
        let available = visible.width * 0.9 - 2 * m
        showsPreviews = snapshots != nil
        let inset = 2 * Self.iconInset
        let perRowLimit = Self.appsPerRow > 0 ? Self.appsPerRow : Int.max

        // Apps wrap onto more rows past the set number per row, or once they would get smaller than the minimum.
        if showsPreviews {
            // The selected app keeps its set size, up to half the row; the rest share what is left, at most
            // `previewScale` of it. Exactly one row holds the selected app, so the panel size does not change with it.
            let aspect = Self.previewSize.height / Self.previewSize.width
            let largeWidth = min(Self.previewSize.width, available * Self.maxSelectedShare - inset)
            let rest = available - largeWidth - inset
            // A preview is at least as tall as a standard icon, so an app shown by its icon gets the standard size.
            let minSmallWidth = Self.standardIconSize / aspect
            let fitting = 1 + max(0, Int(rest / (minSmallWidth + inset)))
            columns = max(1, min(entries.count, perRowLimit, fitting))
            let room = columns > 1 ? rest / CGFloat(columns - 1) - inset : .greatestFiniteMagnitude
            let smallWidth = max(minSmallWidth, min(largeWidth * Self.previewScale, room))
            largeCell = NSSize(width: largeWidth + inset, height: largeWidth * aspect + inset)
            smallCell = NSSize(width: smallWidth + inset, height: smallWidth * aspect + inset)
        } else {
            let fitting = max(1, Int(available / (Self.standardIconSize + inset)))
            columns = max(1, min(entries.count, perRowLimit, fitting))
            let iconSize = Self.standardIconSize
            largeCell = NSSize(width: iconSize + inset, height: iconSize + inset)
            smallCell = largeCell
        }
        rows = (entries.count + columns - 1) / columns
        let size = NSSize(width: 2 * m + largeCell.width + CGFloat(columns - 1) * smallCell.width,
                          height: 2 * m + Self.labelHeight + largeCell.height + CGFloat(rows - 1) * smallCell.height)

        items.forEach { $0.removeFromSuperview() }
        items = entries.enumerated().map { index, entry in
            let item = ItemView(icon: entry.app.icon, dimmed: !entry.hasWindows, inset: Self.iconInset, index: index,
                                showsPreview: showsPreviews)
            item.snapshot = snapshots?[entry.app.processIdentifier]
            item.onHover = { [weak self] in self?.onHover?($0) }
            item.onClick = { [weak self] in self?.onClick?($0) }
            background.addSubview(item)
            return item
        }
        names = entries.map { $0.app.localizedName ?? "" }
        hasWindows = entries.map(\.hasWindows)
        pids = entries.map(\.app.processIdentifier)

        setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                        width: size.width, height: size.height), display: false)
        select(selected)
        orderFrontRegardless()
    }

    func setSnapshot(_ image: CGImage, for pid: pid_t) {
        guard showsPreviews, let index = pids.firstIndex(of: pid) else { return }
        items[index].snapshot = image
    }

    func select(_ index: Int) {
        let m = Self.margin
        let selectedRow = index / columns
        var rowTop = frame.height - m
        for row in 0..<rows {
            let range = row * columns..<min(items.count, (row + 1) * columns)
            let rowHeight = row == selectedRow ? largeCell.height : smallCell.height
            let rowWidth = range.reduce(CGFloat(0)) { $0 + ($1 == index ? largeCell.width : smallCell.width) }
            // Rows are centered; within a row, cells share a center line, so the selected one grows up and down.
            var x = (frame.width - rowWidth) / 2
            for i in range {
                let cell = i == index ? largeCell : smallCell
                items[i].isSelected = i == index
                items[i].frame = NSRect(x: x, y: rowTop - rowHeight + (rowHeight - cell.height) / 2,
                                        width: cell.width, height: cell.height)
                x += cell.width
            }
            rowTop -= rowHeight
        }
        guard items.indices.contains(index) else { return }
        label.stringValue = hasWindows[index] ? names[index] : "\(names[index]) – New Window"
        label.textColor = hasWindows[index] ? .labelColor : .secondaryLabelColor
        label.sizeToFit()
        let width = min(label.frame.width + 8, frame.width - 2 * m)
        let labelX = min(max(items[index].frame.midX - width / 2, m), frame.width - m - width)
        let y = m + (Self.labelHeight - label.frame.height) / 2
        label.frame = NSRect(x: labelX, y: y, width: width, height: label.frame.height)
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
    var snapshot: CGImage? {
        didSet { needsDisplay = true }
    }

    private static let badgeFraction: CGFloat = 0.3
    private static let maxBadgeSize: CGFloat = 48

    private let icon: NSImage?
    private let dimmed: Bool
    private let inset: CGFloat
    private let index: Int
    private let showsPreview: Bool

    init(icon: NSImage?, dimmed: Bool, inset: CGFloat, index: Int, showsPreview: Bool) {
        self.icon = icon
        self.dimmed = dimmed
        self.inset = inset
        self.index = index
        self.showsPreview = showsPreview
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            NSColor.labelColor.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12).fill()
        }
        let content = bounds.insetBy(dx: inset, dy: inset)
        guard showsPreview else {
            // Apps without windows: faded.
            icon?.draw(in: content, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.4 : 1)
            return
        }
        guard let snapshot else {
            // No snapshot (yet): the icon at full height, centered, faded for apps without windows.
            let side = min(content.width, content.height)
            let iconRect = NSRect(x: content.midX - side / 2, y: content.midY - side / 2, width: side, height: side)
            icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.4 : 1)
            return
        }
        let fit = min(content.width / CGFloat(snapshot.width), content.height / CGFloat(snapshot.height))
        let imageSize = NSSize(width: CGFloat(snapshot.width) * fit, height: CGFloat(snapshot.height) * fit)
        let imageRect = NSRect(x: content.midX - imageSize.width / 2, y: content.midY - imageSize.height / 2,
                               width: imageSize.width, height: imageSize.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: imageRect, xRadius: 6, yRadius: 6).addClip()
        NSImage(cgImage: snapshot, size: imageSize).draw(in: imageRect)
        NSGraphicsContext.restoreGraphicsState()
        // The app's icon over the snapshot's bottom-left corner.
        let badge = min(Self.maxBadgeSize, content.height * Self.badgeFraction)
        let badgeRect = NSRect(x: imageRect.minX - badge * 0.2, y: imageRect.minY - badge * 0.2, width: badge, height: badge)
        icon?.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1)
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
