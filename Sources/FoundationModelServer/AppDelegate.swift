import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var statusViewController: StatusViewController!
    private let controller = ServerController()
    private var iconCache: [String: NSImage] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusViewController = StatusViewController(controller: controller)

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = statusViewController

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "Foundation Model Server")
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.wantsLayer = true
        }

        controller.onChange = { [weak self] in
            self?.updateStatusIcon()
            self?.updateBusyAnimation()
            self?.statusViewController.refresh()
        }
        updateStatusIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            statusViewController.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// Which of the four Petit Pomme apple states to show, mirroring
    /// `ServerStatus` plus, while running, the same green/orange/red
    /// `TokenGauge` tier shown in the popover — so the menu bar glyph alone
    /// tells you whether you're nearing the context window limit, no need to
    /// open the popover.
    private func iconName(for status: ServerStatus) -> String {
        switch status {
        case .stopped, .starting:
            return "mipo-sleeping"
        case .error:
            return "mipo-critical"
        case .running:
            switch TokenGauge.tier(forRatio: controller.tokenUsageRatio) {
            case .normal: return "mipo-active"
            case .warning: return "mipo-warning"
            case .critical: return "mipo-critical"
            }
        }
    }

    private static let iconNames = ["mipo-sleeping", "mipo-active", "mipo-warning", "mipo-critical"]

    /// One shared pixels-to-points scale factor for all four icons, computed
    /// from whichever has the most vertical extent (the leaf-up poses are
    /// taller than the sleeping one). Scaling each icon independently to the
    /// same *height* — the previous approach — made the apple body itself
    /// look smaller in the taller poses, since more of that fixed height was
    /// spent on the leaf; a single shared scale keeps the body a consistent
    /// size across all four and just lets the leaf extend further where it
    /// naturally does.
    private lazy var iconScale: CGFloat = {
        let targetHeight: CGFloat = 21
        var maxPixelHeight: CGFloat = 1
        for name in Self.iconNames {
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let data = try? Data(contentsOf: url),
               let rep = NSBitmapImageRep(data: data) {
                maxPixelHeight = max(maxPixelHeight, CGFloat(rep.pixelsHigh))
            }
        }
        return targetHeight / maxPixelHeight
    }()

    private func icon(named name: String) -> NSImage? {
        if let cached = iconCache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        image.size = NSSize(width: CGFloat(rep.pixelsWide) * iconScale, height: CGFloat(rep.pixelsHigh) * iconScale)
        iconCache[name] = image
        return image
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let name = iconName(for: controller.status)
        if let image = icon(named: name) {
            button.image = image
        } else {
            // Fallback for the raw debug binary (no Contents/Resources to load
            // these PNGs from outside the .app bundle built by build-app.sh).
            button.image = NSImage(systemSymbolName: "applelogo", accessibilityDescription: "Petit Pomme")
        }
    }

    /// Gently pulses the menu bar icon's opacity while a request is actively
    /// being handled, so there's visible feedback that the server is doing
    /// something — otherwise a slow request looks identical to an idle one.
    private func updateBusyAnimation() {
        guard let layer = statusItem.button?.layer else { return }
        if controller.isBusy {
            guard layer.animation(forKey: "pulse") == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.55
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: "pulse")
        } else {
            layer.removeAnimation(forKey: "pulse")
            layer.opacity = 1.0
        }
    }
}
