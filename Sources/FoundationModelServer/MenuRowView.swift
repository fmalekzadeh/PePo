import AppKit

/// A plain, native-menu-style row: a left-aligned title, an optional
/// right-aligned keyboard-shortcut hint, and a subtle highlight that only
/// appears on hover — like a real `NSMenu` item, but embeddable directly in a
/// popover's view hierarchy (`NSMenu` itself can't be).
///
/// `NSButton`'s bezel styles (including `.recessed`) all reserve their own
/// internal content padding, which made an earlier version of this row sit
/// visibly indented relative to sibling labels like "Port" — this view has no
/// such padding, so its title lines up exactly flush with the rest of the
/// popover's text.
final class MenuRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let highlightView = NSView()
    private var trackingArea: NSTrackingArea?

    var action: (() -> Void)?

    init(title: String, shortcut: String? = nil) {
        super.init(frame: .zero)
        setUp(title: title, shortcut: shortcut)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setUp(title: String, shortcut: String?) {
        wantsLayer = true

        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 5
        highlightView.layer?.backgroundColor = NSColor.clear.cgColor
        highlightView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(highlightView)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12.5)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        shortcutLabel.stringValue = shortcut ?? ""
        shortcutLabel.font = .systemFont(ofSize: 12.5)
        shortcutLabel.textColor = .secondaryLabelColor
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            // The highlight is allowed to bleed slightly past the row's own
            // flush-left/right text bounds, matching how real menu item
            // highlights extend a little beyond their title.
            highlightView.topAnchor.constraint(equalTo: topAnchor, constant: -1),
            highlightView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 1),
            highlightView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -8),
            highlightView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            shortcutLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            shortcutLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        highlightView.layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.18).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        highlightView.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bounds.contains(point) {
            action?()
        }
    }

    /// Without this, AppKit's event dispatch sends clicks to whichever child
    /// is deepest under the cursor — `titleLabel` or `shortcutLabel` — and
    /// neither of those forwards the event back up, so `mouseUp` above never
    /// actually fired for a click squarely on the row's own text. Claiming
    /// the whole bounds for `self` makes every click in the row land here
    /// regardless of which label visually sits at that point.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        let localPoint = convert(point, from: superview)
        return bounds.contains(localPoint) ? self : nil
    }
}
