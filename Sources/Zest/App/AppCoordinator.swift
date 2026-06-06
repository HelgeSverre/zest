import AppKit

/// Owns the index handle + current scope path + back/forward history, and the
/// one query that drives the file list. Toolbar, sidebar, and browser all talk
/// to this; `onChange` fires after any navigation so observers refresh.
final class AppCoordinator {
    let core: ZestCore?
    private(set) var currentPath: String
    private var backStack: [String] = []
    private var forwardStack: [String] = []

    /// Fired after currentPath changes (navigate/back/forward/up).
    var onChange: (() -> Void)?

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        self.core = support.flatMap { ZestCore(indexPath: $0.appendingPathComponent("zest/index.zst").path) }
        self.currentPath = fm.homeDirectoryForCurrentUser.path
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func navigate(to path: String) {
        let resolved = AppCoordinator.resolve(path, relativeTo: currentPath)
        guard isDirectory(resolved), resolved != currentPath else { return }
        backStack.append(currentPath)
        forwardStack.removeAll()
        currentPath = resolved
        onChange?()
    }

    func goBack()    { guard let p = backStack.popLast() else { return }; forwardStack.append(currentPath); currentPath = p; onChange?() }
    func goForward() { guard let p = forwardStack.popLast() else { return }; backStack.append(currentPath); currentPath = p; onChange?() }
    func goUp()      { let parent = (currentPath as NSString).deletingLastPathComponent; navigate(to: parent.isEmpty ? "/" : parent) }

    /// One index query for the current folder (depth-1 listing), folders first.
    func currentListing() -> [ZestCore.Row] {
        guard let core else { return [] }
        var rows = core.query("", scope: currentPath, maxDepth: 1, maxResults: 100_000)
        rows.sort { a, b in
            let ad = a.kind == 1, bd = b.kind == 1
            if ad != bd { return ad }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return rows
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Resolve ~, ~/…, absolute, or relative-to-base (mirrors the engine's resolveEnteredPath).
    static func resolve(_ raw: String, relativeTo base: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p == "~" { return home }
        if p.hasPrefix("~/") { p = home + String(p.dropFirst(1)) }
        if !p.hasPrefix("/") { p = (base as NSString).appendingPathComponent(p) }
        return (p as NSString).standardizingPath
    }
}
