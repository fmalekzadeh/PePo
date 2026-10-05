import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// The .app bundle's Info.plist already sets LSUIElement to keep us out of the
// Dock/Cmd-Tab; this is a harmless no-op safety net when run as a bare binary
// (e.g. `swift run`) that has no Info.plist at all.
app.setActivationPolicy(.accessory)
app.run()
