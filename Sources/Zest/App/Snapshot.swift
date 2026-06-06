import AppKit

/// Deterministic off-screen UI snapshotting for development verification.
/// `Zest --snapshot <path> [WxH]` renders the real view hierarchy to a PNG with
/// no event loop, no screen capture, and no screen-recording permission — so the
/// rendered UI can be checked from an automated/headless context. NSVisualEffectView
/// vibrancy doesn't sample a backdrop off-screen (renders clear), but the root view's
/// Theme.background shows through, so the captured chrome is faithful.
enum Snapshot {
    static func capture(_ vc: NSViewController, to path: String, size: NSSize) {
        // Realize the window off the visible screen so AppKit lays out + draws it.
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = vc
        window.setContentSize(size)
        window.orderFront(nil)
        // Let async layout / CATransaction commit before capturing.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))

        guard let content = window.contentView else { fail(path, "no contentView"); return }
        content.layoutSubtreeIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            fail(path, "no bitmap rep"); return
        }
        content.cacheDisplay(in: content.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fail(path, "png encode failed"); return
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            log("snapshot written: \(path)  \(Int(size.width))x\(Int(size.height))")
        } catch {
            fail(path, "write failed: \(error)")
        }
        window.orderOut(nil)
    }

    private static func log(_ s: String)  { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    private static func fail(_ p: String, _ s: String) { log("snapshot ERROR (\(p)): \(s)") }
}
