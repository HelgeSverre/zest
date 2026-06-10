import AppKit

/// The structured filter — category, extensions, and plain search text — that
/// drives the index query. Click handlers mutate this directly instead of
/// string-surgery on a freeform `queryText`, which used to clobber adjacent
/// tokens (e.g. clicking a category wiped any plain text the user had typed).
///
/// `parse` and `encoded` are inverses, so a round-trip through `queryText` is
/// lossless. Mirrors the Zig `query_parser` tokenize-on-space semantics.
struct Filter: Equatable {
    /// Canonical lowercased query key (e.g. "code", "images"). Matches the
    /// `Category.all` `queryKey` field and the Zig `parseCategory` values.
    var category: String?
    /// One or more `ext:<e>` filters. Currently the UI only sets one at a time.
    var extensions: Set<String> = []
    /// The plain-text portion of the query. Anything that wasn't a recognized
    /// `key:` token, joined back with spaces. Preserves original case.
    var text: String = ""

    var isEmpty: Bool {
        category == nil && extensions.isEmpty && text.isEmpty
    }

    /// Serializes to the `cat:<k> ext:<e> <text>` form the Zig parser consumes.
    /// Stable ordering (cat first, then ext sorted, then text) so the rendered
    /// queryText is predictable for the search field.
    var encoded: String {
        var parts: [String] = []
        if let cat = category { parts.append("cat:\(cat)") }
        for ext in extensions.sorted() {
            parts.append("ext:\(ext)")
        }
        if !text.isEmpty { parts.append(text) }
        return parts.joined(separator: " ")
    }

    /// Inverse of `encoded`. Tokenize on whitespace (the same way the Zig
    /// `query_parser` does), route `cat:` and `ext:` prefixes to their slots,
    /// collect the rest as text. Unknown qualifiers (`foo:bar`) stay as text,
    /// matching the Zig behaviour.
    static func parse(_ s: String) -> Filter {
        var f = Filter()
        var plainParts: [String] = []
        for token in s.split(separator: " ", omittingEmptySubsequences: true) {
            let lower = token.lowercased()
            if lower.hasPrefix("cat:") {
                let v = String(lower.dropFirst(4))
                if !v.isEmpty { f.category = v }
            } else if lower.hasPrefix("ext:") {
                let v = String(lower.dropFirst(4))
                if !v.isEmpty { f.extensions.insert(v) }
            } else {
                plainParts.append(String(token))
            }
        }
        f.text = plainParts.joined(separator: " ")
        return f
    }
}

/// Owns the index handle + current scope path + back/forward history, and the
/// one query that drives the file list. Toolbar, sidebar, and browser all talk
/// to this; `onChange` fires after any state change so observers refresh.
final class AppCoordinator {
    /// Where the query runs from + how deep it reaches.
    enum Scope { case folder, subfolders, everywhere }

    /// Which column drives the client-side sort.
    enum SortColumn { case name, size, modified, kind, ext }

    let core: ZestCore?
    private(set) var currentPath: String
    private var backStack: [String] = []
    private var forwardStack: [String] = []

    /// Fired after any state change — navigation, query, scope, or sort — so
    /// observers refresh. The sidebar internally caches the histogram and only
    /// recomputes it when the folder context (path + scope) actually changes.
    var onChange: (() -> Void)?

    /// The live query string. Empty == browse mode (subject to scope).
    /// Computed over `filter` — setting it parses the string into a `Filter`
    /// struct (the source of truth for click handlers); reading it encodes
    /// the struct back to the canonical `cat:<k> ext:<e> <text>` form the
    /// Zig parser consumes.
    var queryText: String {
        get { filter.encoded }
        set {
            let parsed = Filter.parse(newValue)
            guard parsed != filter else { return }
            filter = parsed
        }
    }

    /// The structured filter — source of truth for category, extensions, and
    /// search text. Click handlers in the sidebar mutate this directly instead
    /// of round-tripping through `queryText` (which used to silently clobber
    /// adjacent tokens).
    var filter: Filter = .init() {
        didSet {
            guard filter != oldValue else { return }
            notifyChange()
        }
    }

    /// Search root + depth selector. Changing scope implies a different (root,
    /// depth) pair for both the query and the sidebar histogram.
    var scope: Scope = .folder {
        didSet {
            guard scope != oldValue else { return }
            notifyChange()
        }
    }

    /// Active sort column + direction (client-side, applied in `results()`).
    var sortColumn: SortColumn = .name {
        didSet {
            guard sortColumn != oldValue else { return }
            notifyChange()
        }
    }

    var sortAscending: Bool = true {
        didSet {
            guard sortAscending != oldValue else { return }
            notifyChange()
        }
    }

    /// Where the query/sidebar histogram run from. Single source of truth so the
    /// file list and the sidebar can't disagree on scope semantics.
    var scopeRoot: String {
        switch scope {
        case .folder, .subfolders: currentPath
        case .everywhere: "/"
        }
    }

    /// How deep the query/sidebar histogram reach. `.folder` is direct children
    /// only; `.subfolders` and `.everywhere` walk the full subtree.
    var scopeDepth: UInt32 {
        switch scope {
        case .folder: 1
        case .subfolders, .everywhere: .max
        }
    }

    /// True when the list should render search affordances (two-line rows, the
    /// "results" count label): a non-empty query OR a non-folder scope.
    var isSearchMode: Bool {
        !queryText.isEmpty || scope != .folder
    }

    var canGoBack: Bool {
        !backStack.isEmpty
    }

    var canGoForward: Bool {
        !forwardStack.isEmpty
    }

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        core = support.flatMap {
            ZestCore(indexPath: $0.appendingPathComponent("zest/index.zst").path)
        }
        currentPath = fm.homeDirectoryForCurrentUser.path
    }

    // MARK: - Navigation

    func navigate(to path: String) {
        let resolved = Self.resolve(path, relativeTo: currentPath)
        guard isDirectory(resolved), resolved != currentPath else { return }
        backStack.append(currentPath)
        forwardStack.removeAll()
        currentPath = resolved
        resetQueryForNavigation()
        notifyChange()
    }

    func goBack() {
        guard let p = backStack.popLast() else { return }
        forwardStack.append(currentPath)
        currentPath = p
        resetQueryForNavigation()
        notifyChange()
    }

    func goForward() {
        guard let p = forwardStack.popLast() else { return }
        backStack.append(currentPath)
        currentPath = p
        resetQueryForNavigation()
        notifyChange()
    }

    func goUp() {
        let parent = (currentPath as NSString).deletingLastPathComponent
        navigate(to: parent.isEmpty ? "/" : parent)
    }

    /// A folder change clears any active search: empty query + This-folder scope.
    /// Sort is preserved. Set silently (no `onChange`) because the caller fires
    /// `onChange` once after the reset.
    private func resetQueryForNavigation() {
        withoutNotifying {
            queryText = ""
            scope = .folder
        }
    }

    /// Suppresses `notifyChange()` during the block so multi-property updates
    /// (e.g. navigation resets) fire only one callback.
    private var suppressChange = false

    private func notifyChange() {
        guard !suppressChange else { return }
        cachedResults = nil
        onChange?()
    }

    private func withoutNotifying(_ block: () -> Void) {
        suppressChange = true
        block()
        suppressChange = false
    }

    /// One-shot commit from the search field: auto-switch a folder scope to
    /// subfolders when text is present, set the query text, and fire a single
    /// `onChange` for the whole transition (previously two — scope then text —
    /// which ran the full query pipeline twice per keystroke).
    func commitSearch(_ text: String) {
        let before = (filter, scope)
        withoutNotifying {
            if !text.isEmpty, scope == .folder { scope = .subfolders }
            queryText = text
        }
        if before != (filter, scope) { notifyChange() }
    }

    // MARK: - Query

    /// UI result cap. 2,000 keeps the worst keystroke at the engine's
    /// full-blob-scan floor (~135ms ReleaseFast) instead of the seconds the old
    /// 100k cap cost, and bounds the Swift-side materialize/sort work. The
    /// filter bar renders "2,000+" when the cap is hit (see `resultsCapped`).
    static let maxResults = 2_000

    /// True when the last `results()` hit the cap (display "N+" counts).
    var resultsCapped: Bool {
        cachedResults?.count == Self.maxResults
    }

    /// Result set for the current change-tick. Every observer that fires from
    /// one `onChange` (browser list, filter-bar count) shares this single
    /// query instead of re-running the engine. Invalidated in `notifyChange`.
    private var cachedResults: [ZestCore.Row]?

    /// The query that drives the file list: honours `queryText`, `scope`, and the
    /// active sort. Scope maps to (root, depth); sorting is client-side. Cached
    /// per change-tick — safe because all reads and all invalidating mutations
    /// happen on the main thread.
    func results() -> [ZestCore.Row] {
        if let cached = cachedResults { return cached }
        guard let core else { return [] }
        var rows = core.query(
            queryText, scope: scopeRoot, maxDepth: scopeDepth,
            maxResults: UInt32(Self.maxResults))
        applySort(to: &rows)
        cachedResults = rows
        return rows
    }

    // MARK: - Sorting

    /// Apply the active sort column/direction. `.name` ascending keeps folders
    /// first (the browse default); other columns sort purely by their key.
    private func applySort(to rows: inout [ZestCore.Row]) {
        let asc = sortAscending

        func nameTieBreak(_ a: ZestCore.Row, _ b: ZestCore.Row) -> Bool {
            a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        func ascending(_ less: Bool) -> Bool {
            asc ? less : !less
        }

        switch sortColumn {
        case .name:
            rows.sort { a, b in
                if asc {
                    let ad = a.kind == 1
                    let bd = b.kind == 1
                    if ad != bd { return ad }
                }
                let cmp = a.name.localizedCaseInsensitiveCompare(b.name)
                if cmp == .orderedSame { return false }
                return ascending(cmp == .orderedAscending)
            }
        case .size:
            rows.sort { a, b in
                if a.size == b.size { return nameTieBreak(a, b) }
                return ascending(a.size < b.size)
            }
        case .modified:
            rows.sort { a, b in
                if a.mtime == b.mtime { return nameTieBreak(a, b) }
                return ascending(a.mtime < b.mtime)
            }
        case .kind:
            rows.sort { a, b in
                let ka = Category.meta(kind: a.kind, category: a.category).label
                let kb = Category.meta(kind: b.kind, category: b.category).label
                let cmp = ka.localizedCaseInsensitiveCompare(kb)
                if cmp == .orderedSame { return nameTieBreak(a, b) }
                return ascending(cmp == .orderedAscending)
            }
        case .ext:
            rows.sort { a, b in
                let cmp = a.fileExtension.localizedCaseInsensitiveCompare(b.fileExtension)
                if cmp == .orderedSame { return nameTieBreak(a, b) }
                return ascending(cmp == .orderedAscending)
            }
        }
    }

    // MARK: - Path helpers

    /// Resolve ~, ~/…, absolute, or relative-to-base (mirrors the engine's resolveEnteredPath).
    static func resolve(_ raw: String, relativeTo base: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p == "~" { return home }
        if p.hasPrefix("~/") { p = home + String(p.dropFirst(1)) }
        if !p.hasPrefix("/") { p = (base as NSString).appendingPathComponent(p) }
        return (p as NSString).standardizingPath
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}

// MARK: - Row helpers

extension ZestCore.Row {
    /// Lowercased extension of the name, or "" for directories / extensionless.
    var fileExtension: String {
        guard kind != 1 else { return "" }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }
}
