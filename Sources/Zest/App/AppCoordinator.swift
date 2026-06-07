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
  /// `Category.byIndex` `queryKey` field and the Zig `parseCategory` values.
  var category: String?
  /// One or more `ext:<e>` filters. Currently the UI only sets one at a time.
  var extensions: Set<String> = []
  /// The plain-text portion of the query. Anything that wasn't a recognized
  /// `key:` token, joined back with spaces. Preserves original case.
  var text: String = ""

  var isEmpty: Bool { category == nil && extensions.isEmpty && text.isEmpty }

  /// Serializes to the `cat:<k> ext:<e> <text>` form the Zig parser consumes.
  /// Stable ordering (cat first, then ext sorted, then text) so the rendered
  /// queryText is predictable for the search field.
  var encoded: String {
    var parts: [String] = []
    if let cat = category { parts.append("cat:\(cat)") }
    for ext in extensions.sorted() { parts.append("ext:\(ext)") }
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

  /// Fired when the *folder context* changes — navigation, or the scope
  /// selector (the latter implies a different depth/root). Observers that
  /// only care about "which folder is active" subscribe here instead of
  /// `onResultsChange`, so per-keystroke text updates don't re-trigger them.
  var onFolderChange: (() -> Void)?

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
      fireResultsChange()
    }
  }

  /// Search root + depth selector. Changing scope is a *folder-context* change
  /// — it implies a different (root, depth) pair for both the query and the
  /// sidebar histogram — so it fires `onFolderChange` in addition to
  /// `onResultsChange`.
  var scope: Scope = .folder {
    didSet {
      guard scope != oldValue else { return }
      onFolderChange?()
      fireResultsChange()
    }
  }

  /// Active sort column + direction (client-side, applied in `results()`).
  var sortColumn: SortColumn = .name {
    didSet {
      guard sortColumn != oldValue else { return }
      fireResultsChange()
    }
  }
  var sortAscending: Bool = true {
    didSet {
      guard sortAscending != oldValue else { return }
      fireResultsChange()
    }
  }

  /// The query key for the active category, if any. Sidebar reads this to
  /// decide which row to highlight; equivalent to `filter.category`.
  var activeCategoryQueryKey: String? { filter.category }

  /// The active extension filter, if any. Equivalent to `filter.extensions.first`.
  var activeExtensionFilter: String? { filter.extensions.first }

  /// Where the query/sidebar histogram run from. Single source of truth so the
  /// file list and the sidebar can't disagree on scope semantics.
  var scopeRoot: String {
    switch scope {
    case .folder, .subfolders: return currentPath
    case .everywhere: return "/"
    }
  }

  /// How deep the query/sidebar histogram reach. `.folder` is direct children
  /// only; `.subfolders` and `.everywhere` walk the full subtree.
  var scopeDepth: UInt32 {
    switch scope {
    case .folder: return 1
    case .subfolders, .everywhere: return .max
    }
  }

  init() {
    let fm = FileManager.default
    let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    self.core = support.flatMap {
      ZestCore(indexPath: $0.appendingPathComponent("zest/index.zst").path)
    }
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
    onFolderChange?()
  }

  func goBack() {
    guard let p = backStack.popLast() else { return }
    forwardStack.append(currentPath)
    currentPath = p
    resetQueryForNavigation()
    onChange?()
    onFolderChange?()
  }

  func goForward() {
    guard let p = forwardStack.popLast() else { return }
    backStack.append(currentPath)
    currentPath = p
    resetQueryForNavigation()
    onChange?()
    onFolderChange?()
  }
  func goUp() {
    let parent = (currentPath as NSString).deletingLastPathComponent
    navigate(to: parent.isEmpty ? "/" : parent)
  }

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

    var rows = core.query(queryText, scope: scopeRoot, maxDepth: scopeDepth, maxResults: 100_000)
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
          let ad = a.kind == 1
          let bd = b.kind == 1
          if ad != bd { return ad }
        }
        let cmp = a.name.localizedCaseInsensitiveCompare(b.name)
        if cmp == .orderedSame { return false }
        return dir(cmp == .orderedAscending)
      }
    case .size:
      rows.sort { a, b in
        if a.size == b.size {
          return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return dir(a.size < b.size)
      }
    case .modified:
      rows.sort { a, b in
        if a.mtime == b.mtime {
          return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return dir(a.mtime < b.mtime)
      }
    case .kind:
      rows.sort { a, b in
        let ka = Category.meta(kind: a.kind, category: a.category).label
        let kb = Category.meta(kind: b.kind, category: b.category).label
        let cmp = ka.localizedCaseInsensitiveCompare(kb)
        if cmp == .orderedSame {
          return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return dir(cmp == .orderedAscending)
      }
    case .ext:
      rows.sort { a, b in
        let ea = AppCoordinator.ext(of: a)
        let eb = AppCoordinator.ext(of: b)
        let cmp = ea.localizedCaseInsensitiveCompare(eb)
        if cmp == .orderedSame {
          return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
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
