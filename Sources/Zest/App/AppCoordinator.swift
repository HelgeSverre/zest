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

  private(set) var core: ZestCore?
  let userState: UserState
  private(set) var currentPath: String
  private var backStack: [String] = []
  private var forwardStack: [String] = []

  /// Fired after any state change — navigation, query, scope, or sort — so
  /// observers refresh. The sidebar internally caches the histogram and only
  /// recomputes it when the folder context (path + scope) actually changes.
  /// May fire twice per change: once immediately (observers render the
  /// last-delivered rows; `isLoading` is true) and once when the fresh
  /// result set lands.
  var onChange: (() -> Void)?

  private var indexPathForReload: String?
  private var reloadTimer: Timer?

  deinit {
    reloadTimer?.invalidate()
  }

  /// Poll the index file every `indexPollInterval` seconds: if the daemon
  /// published a new index (different inode/size/mtime), or we launched
  /// before the first index existed (core == nil), open the new file and
  /// swap. Rows are copied at the FFI boundary, so dropping the old core is
  /// safe; ARC unmaps it. Idempotent: calling again cancels any existing timer.
  func startIndexReloadTimer() {
    reloadTimer?.invalidate()
    let timer = Timer.scheduledTimer(
      withTimeInterval: Self.indexPollInterval, repeats: true
    ) { [weak self] _ in
      self?.reloadIndexIfChanged()
    }
    timer.tolerance = 1
    reloadTimer = timer
  }

  func reloadIndexIfChanged() {
    guard let path = indexPathForReload else { return }
    guard let onDisk = ZestCore.currentIdentity(of: path) else { return }  // no index yet
    if let core, core.fileIdentity == onDisk { return }  // unchanged
    guard let fresh = ZestCore(indexPath: path) else { return }  // mid-rename; retry next tick
    core = fresh
    notifyChange()  // re-queries against the fresh core + refreshes every observer
  }

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

  /// Active sort column + direction (client-side, applied off-main in
  /// `startQuery`). A sort change re-orders the cached rows in place — no
  /// engine round-trip (see `resortOrRequery`).
  var sortColumn: SortColumn = .name {
    didSet {
      guard sortColumn != oldValue else { return }
      resortOrRequery()
    }
  }

  var sortAscending: Bool = true {
    didSet {
      guard sortAscending != oldValue else { return }
      resortOrRequery()
    }
  }

  /// View ▸ Folders on Top: pin directories before files regardless of the
  /// active sort. Persisted in UserState; lazily seeded from it on first read.
  lazy var foldersOnTop: Bool = userState.foldersOnTop {
    didSet {
      guard foldersOnTop != oldValue else { return }
      userState.setFoldersOnTop(foldersOnTop)
      resortOrRequery()
    }
  }

  /// A sort change re-orders the rows we already have — no engine round-trip.
  /// Mid-flight (loading), fall back to a full re-query so the eventual
  /// delivery carries the new order (the in-flight query snapshotted the old
  /// sort state and would otherwise overwrite a locally re-sorted list).
  private func resortOrRequery() {
    guard !suppressChange else { return }
    if !loading, var rows = cachedResults {
      Self.applySort(
        to: &rows, column: sortColumn, ascending: sortAscending, foldersOnTop: foldersOnTop)
      cachedResults = rows
      onChange?()
    } else {
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
    let zestDir = support?.appendingPathComponent("zest")
    let indexPath = zestDir?.appendingPathComponent("index.zst").path
    core = indexPath.flatMap { ZestCore(indexPath: $0) }
    indexPathForReload = indexPath
    userState = UserState(directory: zestDir)
    currentPath = fm.homeDirectoryForCurrentUser.path
  }

  // MARK: - Pins & folder colors

  func pinFolder(path: String, name: String) {
    userState.addPin(name: name, path: path)
    notifyChange()
  }

  func unpinFolder(path: String) {
    userState.removePin(path: path)
    notifyChange()
  }

  func setFolderColor(for path: String, color: NSColor?) {
    userState.setFolderColor(forPath: path, color: color)
    notifyChange()
  }

  // MARK: - Saved filters

  var savedFilters: [UserState.SavedFilter] {
    userState.filters
  }

  func addSavedFilter(name: String, query: String) {
    userState.addFilter(name: name, query: query)
    notifyChange()
  }

  func removeSavedFilter(at index: Int) {
    userState.removeFilter(at: index)
    notifyChange()
  }

  func updateSavedFilter(at index: Int, name: String, query: String) {
    userState.updateFilter(at: index, name: name, query: query)
    notifyChange()
  }

  func applySavedFilter(_ filter: UserState.SavedFilter) {
    withoutNotifying {
      queryText = filter.query
      if scope == .folder { scope = .subfolders }
    }
    notifyChange()
  }

  // MARK: - Navigation

  @discardableResult
  func navigate(to path: String) -> Bool {
    let resolved = Self.resolve(path, relativeTo: currentPath)
    guard isDirectory(resolved) else { return false }
    guard resolved != currentPath else { return true }  // no-op, not a failure
    backStack.append(currentPath)
    forwardStack.removeAll()
    currentPath = resolved
    resetQueryForNavigation()
    notifyChange()
    return true
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
    startQuery()
    onChange?()  // observers render the last-delivered (stale) rows + loading state now
  }

  /// Kick the initial query once observers are wired (RootViewController).
  func start() {
    notifyChange()
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

  /// How often the app checks whether the daemon published a new index.
  static let indexPollInterval: TimeInterval = 5

  /// True when the last delivered result set hit the cap (display "N+" counts).
  var resultsCapped: Bool {
    cachedResults?.count == Self.maxResults
  }

  /// Result set for the current change-tick, delivered by `startQuery`.
  /// Every observer that fires from one `onChange` (browser list, filter-bar
  /// count) shares this single query. Kept (stale) while a fresh query is in
  /// flight so observers never render an empty flash; written only on the
  /// main thread (a non-stale delivery, or `startQuery`'s no-core reset).
  private var cachedResults: [ZestCore.Row]?

  /// Serial queue for engine queries — one in flight at a time; the
  /// generation check drops stale deliveries (sidebar-style pattern).
  private let queryQueue = DispatchQueue(label: "zest.query", qos: .userInitiated)
  private var queryGeneration = 0

  /// True while a query is in flight for the current state (drives the
  /// filter bar's transient "…" count).
  var isLoading: Bool { loading }

  /// Set on main when `startQuery` dispatches, cleared on main when a
  /// non-stale delivery lands (or immediately when there's no core).
  private var loading = false

  /// Run the query for the current `queryText`/`scope` snapshot off-main and
  /// deliver on main. The engine call uses a strong local `core` captured on
  /// the main thread — never `self.core` from the queue (data race on the
  /// var + mid-swap hazard during index hot-reload); the strong capture
  /// keeps the old mmap alive until the closure finishes, and ARC frees it
  /// on the queue thread afterwards. Sort state is snapshotted alongside the
  /// query so the sort also runs off-main, on the queue. A hot-reload (or
  /// any state change) bumps the generation via `notifyChange`, so a late
  /// delivery from an old core/query is dropped on main before it can
  /// overwrite fresh state.
  private func startQuery() {
    queryGeneration += 1
    let gen = queryGeneration
    guard let core else {
      // Nothing will deliver — results must read empty, not stale.
      loading = false
      cachedResults = nil
      return
    }
    loading = true
    let q = queryText
    let root = scopeRoot
    let depth = scopeDepth
    let sortCol = sortColumn
    let sortAsc = sortAscending
    let foldersTop = foldersOnTop
    queryQueue.async { [weak self] in
      var rows = core.query(q, scope: root, maxDepth: depth, maxResults: UInt32(Self.maxResults))
      Self.applySort(to: &rows, column: sortCol, ascending: sortAsc, foldersOnTop: foldersTop)
      DispatchQueue.main.async {
        guard let self, self.queryGeneration == gen else { return }
        self.cachedResults = rows
        self.loading = false
        self.onChange?()  // second pass: observers render fresh rows
      }
    }
  }

  /// Last delivered rows. Stale (previous change-tick) while a query is in
  /// flight; empty before the first delivery or when no index is open.
  /// Never blocks.
  func results() -> [ZestCore.Row] {
    cachedResults ?? []
  }

  // MARK: - Sorting

  /// Sort with precomputed keys: one lowercased key per row (O(n)) and cheap
  /// byte compares in the O(n log n) sort, instead of per-comparison ICU
  /// calls. Ordering note: plain Unicode-scalar ordering of lowercased
  /// names, not locale collation — imperceptible for filenames and ~50x
  /// cheaper. Runs off-main in the query pipeline; pure function.
  ///
  /// `.name` ascending keeps folders first (browse default); other columns
  /// sort purely by their key. Folders-first applies only when ascending —
  /// exactly mirroring the previous behaviour.
  ///
  /// `foldersOnTop` (View ▸ Folders on Top) pins directories before files for
  /// every column/direction; within each group the column sort still applies.
  /// Internal (not private) so sort semantics stay unit-testable.
  static func applySort(
    to rows: inout [ZestCore.Row], column: SortColumn, ascending asc: Bool,
    foldersOnTop: Bool = false
  ) {
    func ascending(_ less: Bool) -> Bool { asc ? less : !less }
    let nameKeys = rows.map { $0.name.lowercased() }
    var order = Array(rows.indices)

    switch column {
    case .name:
      order.sort { i, j in
        if asc {
          let ad = rows[i].kind == 1
          let bd = rows[j].kind == 1
          if ad != bd { return ad }
        }
        if nameKeys[i] == nameKeys[j] { return false }
        return ascending(nameKeys[i] < nameKeys[j])
      }
    case .size:
      order.sort { i, j in
        if rows[i].size == rows[j].size { return nameKeys[i] < nameKeys[j] }
        return ascending(rows[i].size < rows[j].size)
      }
    case .modified:
      order.sort { i, j in
        if rows[i].mtime == rows[j].mtime { return nameKeys[i] < nameKeys[j] }
        return ascending(rows[i].mtime < rows[j].mtime)
      }
    case .kind:
      let kindKeys = rows.map { Category.meta(kind: $0.kind, category: $0.category).label }
      order.sort { i, j in
        if kindKeys[i] == kindKeys[j] { return nameKeys[i] < nameKeys[j] }
        return ascending(kindKeys[i] < kindKeys[j])
      }
    case .ext:
      let extKeys = rows.map { $0.fileExtension }
      order.sort { i, j in
        if extKeys[i] == extKeys[j] { return nameKeys[i] < nameKeys[j] }
        return ascending(extKeys[i] < extKeys[j])
      }
    }
    rows = order.map { rows[$0] }

    // Stable partition: the column sort above is preserved within each group.
    if foldersOnTop {
      rows = rows.filter { $0.kind == 1 } + rows.filter { $0.kind != 1 }
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
