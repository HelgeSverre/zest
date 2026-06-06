import AppKit

/// Owns the index handle + current scope path + back/forward history, and the
/// one query that drives the file list. Toolbar, sidebar, and browser all talk
/// to this; `onChange` fires after any navigation so observers refresh.
final class AppCoordinator {
    /// Where the query runs from + how deep it reaches.
    enum Scope { case folder, subfolders, everywhere }

    /// Which column drives the client-side sort.
    enum SortColumn { case name, size, modified, kind, ext }

    let core: ZestCore?
    private(set) var currentPath: String
    private var backStack: [String] = []
    private var forwardStack: [String] = []

    /// Fired after currentPath changes (navigate/back/forward/up).
    var onChange: (() -> Void)?

    /// Fired when the query model (text / scope / sort) changes without a
    /// navigation, so the list + count + filter bar refresh in place.
    var onResultsChange: (() -> Void)?

    /// The live query string. Empty == browse mode (subject to scope).
    var queryText: String = "" {
        didSet { guard queryText != oldValue else { return }; fireResultsChange() }
    }

    /// Search root + depth selector.
    var scope: Scope = .folder {
        didSet { guard scope != oldValue else { return }; fireResultsChange() }
    }

    /// Active sort column + direction (client-side, applied in `results()`).
    var sortColumn: SortColumn = .name {
        didSet { guard sortColumn != oldValue else { return }; fireResultsChange() }
    }
    var sortAscending: Bool = true {
        didSet { guard sortAscending != oldValue else { return }; fireResultsChange() }
    }

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        self.core = support.flatMap { ZestCore(indexPath: $0.appendingPathComponent("zest/index.zst").path) }
        self.currentPath = fm.homeDirectoryForCurrentUser.path
    }

    /// True when the list should render search affordances (two-line rows, the
    /// "results" count label): a non-empty query OR a non-folder scope.
    var isSearchMode: Bool { !queryText.isEmpty || scope != .folder }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func navigate(to path: String) {
        let resolved = AppCoordinator.resolve(path, relativeTo: currentPath)
        guard isDirectory(resolved), resolved != currentPath else { return }
        backStack.append(currentPath)
        forwardStack.removeAll()
        currentPath = resolved
        resetQueryForNavigation()
        onChange?()
    }

    func goBack()    { guard let p = backStack.popLast() else { return }; forwardStack.append(currentPath); currentPath = p; resetQueryForNavigation(); onChange?() }
    func goForward() { guard let p = forwardStack.popLast() else { return }; backStack.append(currentPath); currentPath = p; resetQueryForNavigation(); onChange?() }
    func goUp()      { let parent = (currentPath as NSString).deletingLastPathComponent; navigate(to: parent.isEmpty ? "/" : parent) }

    /// A folder change clears any active search: empty query + This-folder scope.
    /// Sort is preserved. Set silently (no `onResultsChange`) because the caller
    /// fires `onChange`, which already refreshes all observers from this state.
    private func resetQueryForNavigation() {
        suppressResultsChange = true
        queryText = ""
        scope = .folder
        suppressResultsChange = false
    }

    /// Set during a navigation reset so the property `didSet`s don't double-fire
    /// `onResultsChange` (navigation refreshes via `onChange`).
    private var suppressResultsChange = false

    private func fireResultsChange() {
        guard !suppressResultsChange else { return }
        onResultsChange?()
    }

    /// One index query for the current folder (depth-1 listing), folders first.
    /// Kept for callers that want the plain browse listing; the file list itself
    /// uses `results()` so search/scope/sort flow through one path.
    func currentListing() -> [ZestCore.Row] {
        results()
    }

    /// The query that drives the file list: honours `queryText`, `scope`, and the
    /// active sort. Scope maps to (root, depth); sorting is client-side.
    func results() -> [ZestCore.Row] {
        guard let core else { return [] }

        let scopeRoot: String
        let depth: UInt32
        switch scope {
        case .folder:     scopeRoot = currentPath; depth = 1
        case .subfolders: scopeRoot = currentPath; depth = .max
        case .everywhere: scopeRoot = "/";         depth = .max
        }

        var rows = core.query(queryText, scope: scopeRoot, maxDepth: depth, maxResults: 100_000)
        sort(&rows)
        return rows
    }

    /// Apply the active sort column/direction. `.name` ascending keeps folders
    /// first (the browse default); other columns sort purely by their key.
    private func sort(_ rows: inout [ZestCore.Row]) {
        let asc = sortAscending
        func dir(_ ordered: Bool) -> Bool { asc ? ordered : !ordered }

        switch sortColumn {
        case .name:
            rows.sort { a, b in
                if asc {  // folders-first only in the natural ascending browse order
                    let ad = a.kind == 1, bd = b.kind == 1
                    if ad != bd { return ad }
                }
                let cmp = a.name.localizedCaseInsensitiveCompare(b.name)
                if cmp == .orderedSame { return false }
                return dir(cmp == .orderedAscending)
            }
        case .size:
            rows.sort { a, b in
                if a.size == b.size { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
                return dir(a.size < b.size)
            }
        case .modified:
            rows.sort { a, b in
                if a.mtime == b.mtime { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
                return dir(a.mtime < b.mtime)
            }
        case .kind:
            rows.sort { a, b in
                let ka = Category.meta(kind: a.kind, category: a.category).label
                let kb = Category.meta(kind: b.kind, category: b.category).label
                let cmp = ka.localizedCaseInsensitiveCompare(kb)
                if cmp == .orderedSame { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
                return dir(cmp == .orderedAscending)
            }
        case .ext:
            rows.sort { a, b in
                let ea = AppCoordinator.ext(of: a), eb = AppCoordinator.ext(of: b)
                let cmp = ea.localizedCaseInsensitiveCompare(eb)
                if cmp == .orderedSame { return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending }
                return dir(cmp == .orderedAscending)
            }
        }
    }

    /// Lowercased extension of a row's name, or "" for directories / extensionless.
    private static func ext(of r: ZestCore.Row) -> String {
        guard r.kind != 1 else { return "" }
        guard let dot = r.name.lastIndex(of: "."), dot != r.name.startIndex else { return "" }
        return r.name[r.name.index(after: dot)...].lowercased()
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
