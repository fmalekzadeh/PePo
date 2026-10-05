import AppKit

/// A small standalone "About" window: product name, version, copyright, and a
/// contact link — opened from the small info button in the popover.
@MainActor
final class AboutWindowController: NSWindowController {
    convenience init() {
        let contentView = AboutWindowController.makeContentView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 322),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "About Petit Pomme"
        window.isReleasedWhenClosed = false
        window.center()
        window.contentView = contentView
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private static func makeContentView() -> NSView {
        let iconView = NSImageView()
        iconView.image = NSApp.applicationIconImage
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.widthAnchor.constraint(equalToConstant: 44).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let nameLabel = NSTextField(labelWithString: "Petit Pomme")
        nameLabel.font = .systemFont(ofSize: 18, weight: .semibold)

        let headerRow = NSStackView(views: [iconView, nameLabel])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 10

        let contentWidth: CGFloat = 260 // window width (300) minus 20pt side insets

        let subtitleLabel = NSTextField(wrappingLabelWithString: "PePo gives any app or script on your Mac local API access to Apple's on-device Foundation Model — start the server from the menu bar, then point your own tool at it or try the built-in Test Chat window, entirely offline.")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.preferredMaxLayoutWidth = contentWidth

        let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let versionLabel = NSTextField(labelWithString: "Version \(bundleVersion)")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .secondaryLabelColor

        let copyrightLabel = NSTextField(labelWithString: "© 2026 PathPilot LLC")
        copyrightLabel.font = .systemFont(ofSize: 11)
        copyrightLabel.textColor = .secondaryLabelColor

        let disclaimerLabel = NSTextField(wrappingLabelWithString: "Provided as-is, with no warranty. A personal project, not affiliated with or endorsed by any employer.")
        disclaimerLabel.font = .systemFont(ofSize: 10)
        disclaimerLabel.textColor = .tertiaryLabelColor
        disclaimerLabel.preferredMaxLayoutWidth = contentWidth

        let coffeeLink = NSTextField(labelWithString: "")
        let coffeeString = NSMutableAttributedString(
            string: "Found this helpful? ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        let coffeeLinkPart = NSMutableAttributedString(string: "Buy me a coffee!")
        coffeeLinkPart.addAttributes(
            [
                .font: NSFont.systemFont(ofSize: 11),
                .link: "https://buymeacoffee.com/doon",
            ],
            range: NSRange(location: 0, length: coffeeLinkPart.length)
        )
        coffeeString.append(coffeeLinkPart)
        coffeeLink.attributedStringValue = coffeeString
        coffeeLink.allowsEditingTextAttributes = true
        coffeeLink.isSelectable = true

        let contactLink = NSTextField(labelWithString: "")
        let linkString = NSMutableAttributedString(string: "Feridoon \u{201C}Doon\u{201D} Malekzadeh")
        linkString.addAttribute(.link, value: "mailto:doon@malekzadeh.net", range: NSRange(location: 0, length: linkString.length))
        linkString.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: NSRange(location: 0, length: linkString.length))
        contactLink.attributedStringValue = linkString
        contactLink.allowsEditingTextAttributes = true
        contactLink.isSelectable = true

        let stack = NSStackView(views: [
            headerRow,
            subtitleLabel,
            versionLabel,
            NSBox.aboutSeparator(),
            coffeeLink,
            contactLink,
            copyrightLabel,
            NSBox.aboutSeparator(),
            disclaimerLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 322))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        return container
    }
}

private extension NSBox {
    static func aboutSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
