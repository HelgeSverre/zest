import AppKit

// Non-bundled executable (preserves `zest /path` ergonomics, like today's app).
let app = NSApplication.shared

// Dev verification: `Zest --snapshot <path> [WxH]` renders the UI off-screen to a
// PNG and exits (no event loop). Used to check rendering during development.
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.accessory)
    let path = CommandLine.arguments[i + 1]
    var size = NSSize(width: 1180, height: 760)
    if i + 2 < CommandLine.arguments.count {
        let parts = CommandLine.arguments[i + 2].split(separator: "x")
        if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) {
            size = NSSize(width: w, height: h)
        }
    }
    Snapshot.capture(RootViewController(), to: path, size: size)
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)   // show in Dock / accept focus when unbundled
app.run()
