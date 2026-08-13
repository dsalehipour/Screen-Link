import AppKit

/// A menu row that does not take the menu down with it.
///
/// Both switches that hand out an address start something that takes a while — a tunnel is twenty
/// seconds of Cloudflare allocating a hostname and beginning to route it — and the thing they
/// produce, the QR code, is the entire reason the menu was opened. A standard item dismisses the
/// menu when it is clicked, which meant starting that wait blind and clicking back in to guess
/// whether it was over yet. AppKit does not dismiss for an item that draws itself, so this one is
/// drawn: the wait and the code then both happen in front of the person who asked for them.
///
/// The cost is doing by hand what a menu item gets for free — the highlight, the checkmark column,
/// the menu font. It is kept to exactly that and no more, so it sits among ordinary items without
/// announcing itself.
final class MenuToggleView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let check = NSTextField(labelWithString: "✓")
    private weak var target: AnyObject?
    private let action: Selector
    private var hovered = false

    /// The inset AppKit leaves either side of a highlighted row, and the width of the column it
    /// keeps to the left of a title for the checkmark.
    private static let highlightInset: CGFloat = 5
    private static let titleIndent: CGFloat = 21
    private static let rowHeight: CGFloat = 22

    init(title: String, isOn: Bool, target: AnyObject, action: Selector) {
        self.target = target
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: Self.rowHeight))

        for field in [label, check] {
            field.font = NSFont.menuFont(ofSize: 0)
            field.textColor = .labelColor
            addSubview(field)
        }
        label.stringValue = title
        check.isHidden = !isOn

        label.sizeToFit()
        check.sizeToFit()
        label.frame.origin = NSPoint(x: Self.titleIndent, y: (Self.rowHeight - label.frame.height) / 2)
        check.frame.origin = NSPoint(x: 7, y: (Self.rowHeight - check.frame.height) / 2)
        // Wide enough for its own title; the menu is as wide as the widest thing in it, and the QR
        // above is wider than either of these.
        frame.size.width = max(260, label.frame.maxX + 12)
    }

    required init?(coder: NSCoder) { fatalError("not created from a nib") }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered else { return }
        // `selectedMenuItemColor` is the obvious one and has been deprecated since Big Sur, when
        // menu highlights became the accent colour behind a rounded rectangle. This is that colour.
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: Self.highlightInset, dy: 0),
                     xRadius: 4, yRadius: 4).fill()
    }

    /// Tracked rather than read from `enclosingMenuItem.isHighlighted`, because that property
    /// changing does not itself ask for a redraw, and a row that highlights a beat late feels broken.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseMoved(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func mouseUp(with event: NSEvent) {
        // A drag that began here and ended somewhere else is not a click on this row.
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    private func setHovered(_ value: Bool) {
        guard value != hovered else { return }
        hovered = value
        let colour: NSColor = value ? .selectedMenuItemTextColor : .labelColor
        label.textColor = colour
        check.textColor = colour
        needsDisplay = true
    }
}
