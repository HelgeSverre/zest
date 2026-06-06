import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let count = liveCount()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Zest — FFI smoke"
        window.backgroundColor = Theme.background
        window.center()

        let label = NSTextField(labelWithString: count)
        label.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
        label.textColor = Theme.text
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open the real index and run a home-folder listing; report the count.
    private func liveCount() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let indexPath = appSupport.appendingPathComponent("zest/index.zst").path
        guard let core = ZestCore(indexPath: indexPath) else {
            return "No index — run zest-indexer --full-scan ~"
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let rows = core.query("", scope: home, maxDepth: 1, maxResults: 100_000)
        let line = "Zig core OK · \(rows.count) entries in \(home)"
        print(line)
        return line
    }
}
