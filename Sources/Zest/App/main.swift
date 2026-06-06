import AppKit

// Non-bundled executable (preserves `zest /path` ergonomics, like today's app).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)   // show in Dock / accept focus when unbundled
app.run()
