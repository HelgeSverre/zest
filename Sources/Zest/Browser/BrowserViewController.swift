import AppKit

// MARK: - Model

/// One row of the file list. A class (not struct) so the formatted display
/// strings can be lazy — only the ~30 visible rows ever pay formatting cost.
/// Lazy vars are accessed on the main thread only (cell config + status bar).
final class FileItem {
  let name: String
  /// Absolute path (dirPath + "/" + name).
  let path: String
  /// Containing directory (for the search-mode path line).
  let dirPath: String
  let isDirectory: Bool
  /// Raw byte size; formatted lazily into `sizeText`.
  let size: UInt64
  /// Unix-seconds mtime; formatted lazily into `isoDate`/`agoText`.
  let mtime: Int64
  /// "Folder" / "Code" / …
  let kindLabel: String
  let kindColor: NSColor
  /// SF Symbol name.
  let symbol: String
  /// Category tint.
  let symbolColor: NSColor
  /// "swift" / "—".
  let extText: String
  /// Folder color tint (from folder_colors.json), nil when unset.
  let folderColor: NSColor?

  /// Folders show their recursive subtree size — the v4 index bakes it into
  /// the size column, so this is the same O(1) read as a file's size.
  lazy var sizeText: String = Self.formatSize(size)
  lazy var isoDate: String = Self.isoFormatter.string(
    from: Date(timeIntervalSince1970: TimeInterval(mtime)))
  lazy var agoText: String = Self.relativeText(from: mtime)

  init(
    name: String, path: String, dirPath: String, isDirectory: Bool,
    size: UInt64, mtime: Int64,
    kindLabel: String, kindColor: NSColor,
    symbol: String, symbolColor: NSColor,
    extText: String, folderColor: NSColor? = nil
  ) {
    self.name = name
    self.path = path
    self.dirPath = dirPath
    self.isDirectory = isDirectory
    self.size = size
    self.mtime = mtime
    self.kindLabel = kindLabel
    self.kindColor = kindColor
    self.symbol = symbol
    self.symbolColor = symbolColor
    self.extText = extText
    self.folderColor = folderColor
  }

  /// Hand-rolled size formatter: avoids ByteCountFormatter overhead and uses
  /// SI (1000-based) units consistent with Finder's "file size" display.
  static func formatSize(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1000, unit < units.count - 1 {
      value /= 1000
      unit += 1
    }
    return unit == 0 ? "\(bytes) B" : String(format: "%.1f %@", value, units[unit])
  }

  // DateFormatter is not thread-safe; lazy vars (and thus this) are
  // main-thread only per the class doc.
  private static let isoFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  /// Relative bucket from a unix-seconds mtime: <1d "today", <30d "Nd ago",
  /// <365d "Nmo ago", else "Ny ago".
  static func relativeText(from mtime: Int64) -> String {
    let now = Int64(Date().timeIntervalSince1970)
    let days = max(0, (now - mtime) / 86400)
    if days < 1 { return "today" }
    if days < 30 { return "\(days)d ago" }
    if days < 365 { return "\(days / 30)mo ago" }
    return "\(days / 365)y ago"
  }
}

// MARK: - View controller

/// The app's centerpiece: a view-based NSTableView showing one index query
/// (the home-folder listing, depth 1). Replaces the placeholder. Columns and
/// row chrome follow the redesign spec §7 + the v2 prototype's browse mode.
final class BrowserViewController: NSViewController {
  private let coordinator: AppCoordinator
  private var items: [FileItem] = []
  /// Snapshot of the coordinator's search mode at the last `reload()`, so cell
  /// builders + `heightOfRow` agree within a single table pass.
  private var searchMode = false

  private let scrollView = NSScrollView()
  private let tableView = ZestTableView()
  private var emptyLabel: NSTextField?

  // MARK: Reload key — context identity for selection/scroll policy

  /// Captures the three axes that define a "different context" for the file
  /// list. When all three match the previous reload the table is showing the
  /// same logical folder/query, so selection should be preserved. When any one
  /// differs (navigation, search text change, scope change) we reset to row 0.
  private struct ReloadKey: Equatable {
    let path: String
    let query: String
    let scope: AppCoordinator.Scope
  }
  private var lastReloadKey: ReloadKey?

  /// Derived accent family (dark) used by the selection chrome.
  fileprivate static let accent = Theme.darkAccent

  // Column identifiers.
  private static let colName = NSUserInterfaceItemIdentifier("name")
  private static let colSize = NSUserInterfaceItemIdentifier("size")
  private static let colMod = NSUserInterfaceItemIdentifier("modified")
  private static let colKind = NSUserInterfaceItemIdentifier("kind")
  private static let colExt = NSUserInterfaceItemIdentifier("ext")

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) not used")
  }

  override func loadView() {
    let v = NSView()
    v.wantsLayer = true
    v.layer?.backgroundColor = Theme.background.cgColor
    view = v
  }

  /// Fired when the selected row changes; carries a status-bar summary
  /// (`"<name> — <Kind>"` plus `" · <size>"` for files) or nil for no selection.
  var onSelectionChange: ((String?) -> Void)?

  override func viewDidLoad() {
    super.viewDidLoad()
    buildTable()
    buildEmptyState()
    tableView.target = self
    tableView.doubleAction = #selector(handleDoubleClick)
    tableView.onActivateSelection = {
      [weak self] in
      self?.activate(row: self?.tableView.selectedRow ?? -1)
    }
    tableView.menuForRow = {
      [weak self] row in self?.buildContextMenu(forRow: row)
    }
    reload()
  }

  // MARK: Data

  /// Re-run the coordinator's query (query/scope/sort aware), remap, and refresh
  /// the table (or empty state). Picks the row height (34 browse / 48 search).
  ///
  /// Selection/scroll policy (two-pass async aware):
  /// - Context changed (path, query, or scope differs from last call): reset to
  ///   row 0 + scroll top. This covers pass 1 of a navigation event.
  /// - Same context (pass 2 delivery, hot-reload, sort re-order): try to
  ///   re-select the item by path. If the item is still present, no scroll.
  ///   If it disappeared (stale pass 1 item gone in pass 2), and NSTableView
  ///   cleared the selection after reloadData(), fall back to row 0.
  /// - Empty: deselect all.
  ///
  /// NSTableView clears (sets selectedRow = -1) or clamps selection after
  /// reloadData() when the previously selected row is out of range; we capture
  /// `selectedPath` before replacing `items` so the same-context branch can
  /// find the item in the new list even if its index shifted.
  func reload() {
    searchMode = coordinator.isSearchMode

    // Capture the currently-selected item's path BEFORE we replace `items` so
    // the same-context branch can relocate it in the refreshed list.
    let selectedPath =
      tableView.selectedRow >= 0 && tableView.selectedRow < items.count
      ? items[tableView.selectedRow].path : nil

    items = coordinator.results().map { makeItem(from: $0) }
    updateSortIndicator()

    let isEmpty = items.isEmpty
    scrollView.isHidden = isEmpty
    emptyLabel?.isHidden = !isEmpty
    if isEmpty {
      // TODO: bundled-app copy should suggest zest-indexer --full-scan ~ instead of the repo-local just recipe.
      if coordinator.core == nil {
        emptyLabel?.stringValue =
          "No search index yet — run \"just index\" to build it. Zest will pick it up automatically."
      } else if coordinator.isLoading {
        emptyLabel?.stringValue = ""  // in flight — don't claim "No results" yet
      } else {
        emptyLabel?.stringValue = coordinator.isSearchMode ? "No results" : "Empty folder"
      }
    }

    tableView.reloadData()  // re-asks heightOfRow, so the 34/48 switch applies

    let key = ReloadKey(
      path: coordinator.currentPath,
      query: coordinator.queryText,
      scope: coordinator.scope)
    let contextChanged = key != lastReloadKey
    lastReloadKey = key

    if isEmpty {
      tableView.deselectAll(nil)
    } else if contextChanged {
      // Real navigation / search change: reset to the top.
      tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      tableView.scrollRowToVisible(0)
    } else if let selectedPath, let idx = items.firstIndex(where: { $0.path == selectedPath }) {
      // Same context (delivery pass, hot-reload, sort): keep the user's
      // selection. Scroll position is intentionally left alone so in-place
      // refreshes don't jump the viewport.
      tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
    } else {
      // Previously selected item is gone (or nothing was selected): fall back
      // to row 0. reloadData() can preserve a same-index selection that now
      // points at a different item — don't leave that lying around.
      tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      tableView.scrollRowToVisible(0)
    }

    // Push the current selection summary directly: `selectRowIndexes` only
    // posts a change notification when the row actually changes, so a reload
    // that lands on the same row would otherwise leave the status bar stale.
    pushSelectionSummary()
  }

  /// Compute + emit the status-bar summary for the current selection.
  private func pushSelectionSummary() {
    onSelectionChange?(currentSelectionSummary())
  }

  /// The status-bar summary for the current selection: `"<name> — <Kind>"`,
  /// plus `" · <size>"` for files. Nil when nothing is selected. Used both to
  /// emit on change and to seed the status bar after the callback is wired.
  func currentSelectionSummary() -> String? {
    let row = tableView.selectedRow
    guard row >= 0, row < items.count else {
      return nil
    }
    let item = items[row]
    var summary = "\(item.name) — \(item.kindLabel)"
    if !item.isDirectory {
      summary += " · \(item.sizeText)"
    }
    return summary
  }

  @objc private func handleDoubleClick() {
    activate(row: tableView.clickedRow)
  }

  /// Open the currently selected row, mirroring Return/Enter. No-op if nothing
  /// is selected. Public so the AppDelegate menu action (⌘↓) can reach it.
  func openSelected() {
    activate(row: tableView.selectedRow)
  }

  /// Open a row: folders navigate the browser, files open in their default app.
  private func activate(row: Int) {
    guard row >= 0, row < items.count else {
      return
    }
    let item = items[row]
    if item.isDirectory {
      if !coordinator.navigate(to: item.path) { NSSound.beep() }
    } else {
      NSWorkspace.shared.open(URL(fileURLWithPath: item.path))
    }
  }

  // MARK: Context menu

  /// Build a per-click menu targeting `row` (the right-clicked row). Actions
  /// capture the item so they fire against the clicked row, not the selection.
  private func buildContextMenu(forRow row: Int) -> NSMenu? {
    guard row >= 0, row < items.count else {
      return nil
    }
    let item = items[row]
    let menu = NSMenu()

    if item.isDirectory {
      let isPinned = coordinator.userState.isPinned(path: item.path)
      let pinItem = NSMenuItem(
        title: isPinned ? "Remove from Pinned" : "Pin to Sidebar",
        action: #selector(menuTogglePin(_:)), keyEquivalent: "")
      pinItem.target = self
      pinItem.representedObject = item.path
      menu.addItem(pinItem)

      let colorMenu = NSMenu()
      let colorItem = NSMenuItem(title: "Folder Color", action: nil, keyEquivalent: "")
      colorItem.submenu = colorMenu

      let none = NSMenuItem(title: "None", action: #selector(menuSetColor(_:)), keyEquivalent: "")
      none.target = self
      none.representedObject = (item.path, nil as NSColor?) as (String, NSColor?)
      none.image = Self.emptyColorSwatch()
      colorMenu.addItem(none)

      for preset in Self.folderColorPresets {
        let mi = NSMenuItem(title: "", action: #selector(menuSetColor(_:)), keyEquivalent: "")
        mi.target = self
        mi.representedObject = (item.path, preset.color) as (String, NSColor)
        mi.image = Self.colorSwatch(preset.color, label: preset.name)
        colorMenu.addItem(mi)
      }
      menu.addItem(colorItem)

      menu.addItem(.separator())
    }

    let open = NSMenuItem(
      title: "Open", action: #selector(menuOpen(_:)), keyEquivalent: "",
    )
    open.target = self
    open.representedObject = item.path
    menu.addItem(open)

    menu.addItem(.separator())

    let reveal = NSMenuItem(
      title: "Reveal in Finder", action: #selector(menuReveal(_:)), keyEquivalent: "",
    )
    reveal.target = self
    reveal.representedObject = item.path
    menu.addItem(reveal)

    let copy = NSMenuItem(
      title: "Copy Path", action: #selector(menuCopyPath(_:)), keyEquivalent: "",
    )
    copy.target = self
    copy.representedObject = item.path
    menu.addItem(copy)

    let term = NSMenuItem(
      title: "Open in Terminal", action: #selector(menuOpenTerminal(_:)), keyEquivalent: "",
    )
    term.target = self
    term.representedObject = item.isDirectory ? item.path : item.dirPath
    menu.addItem(term)

    return menu
  }

  @objc private func menuOpen(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String else {
      return
    }
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    if isDir.boolValue {
      if !coordinator.navigate(to: path) { NSSound.beep() }
    } else {
      NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
  }

  @objc private func menuReveal(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String else {
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }

  @objc private func menuCopyPath(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String else {
      return
    }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(path, forType: .string)
  }

  /// Open the user's preferred terminal at the given directory. Resolves the
  /// app from `$ZEST_TERMINAL` / `$TERMINAL` (bundle id or display name) and
  /// falls back to Apple Terminal when nothing is set. Robust: if nothing
  /// resolves, no-op rather than throwing.
  @objc private func menuOpenTerminal(_ sender: NSMenuItem) {
    guard let dir = sender.representedObject as? String else {
      return
    }
    guard let term = Self.resolvePreferredTerminal() else {
      return
    }
    let dirURL = URL(fileURLWithPath: dir)
    let config = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.open(
      [dirURL], withApplicationAt: term.appURL, configuration: config, completionHandler: nil,
    )
  }

  @objc private func menuTogglePin(_ sender: NSMenuItem) {
    guard let path = sender.representedObject as? String else { return }
    if coordinator.userState.isPinned(path: path) {
      coordinator.unpinFolder(path: path)
    } else {
      let name = (path as NSString).lastPathComponent
      coordinator.pinFolder(path: path, name: name)
    }
  }

  @objc private func menuSetColor(_ sender: NSMenuItem) {
    guard let (path, color) = sender.representedObject as? (String, NSColor?) else { return }
    coordinator.setFolderColor(for: path, color: color)
  }

  struct Preset {
    let name: String
    let color: NSColor
  }

  static let folderColorPresets: [Preset] = [
    Preset(name: "Red", color: NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)),
    Preset(name: "Orange", color: NSColor(srgbRed: 1, green: 0.58, blue: 0, alpha: 1)),
    Preset(name: "Yellow", color: NSColor(srgbRed: 1, green: 0.8, blue: 0, alpha: 1)),
    Preset(name: "Green", color: NSColor(srgbRed: 0.2, green: 0.78, blue: 0.35, alpha: 1)),
    Preset(name: "Blue", color: NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)),
    Preset(name: "Purple", color: NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1)),
    Preset(name: "Pink", color: NSColor(srgbRed: 1, green: 0.18, blue: 0.33, alpha: 1)),
    Preset(name: "Gray", color: NSColor(srgbRed: 0.56, green: 0.56, blue: 0.58, alpha: 1)),
  ]

  static func colorSwatch(_ color: NSColor, label: String) -> NSImage {
    let size = NSSize(width: 12, height: 12)
    let img = NSImage(size: size)
    img.lockFocus()
    let path = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 12, height: 12))
    color.setFill()
    path.fill()
    img.unlockFocus()
    img.accessibilityDescription = label
    return img
  }

  static func emptyColorSwatch() -> NSImage {
    let size = NSSize(width: 12, height: 12)
    let img = NSImage(size: size)
    img.lockFocus()
    let path = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 12, height: 12))
    Theme.textTertiary.setStroke()
    path.lineWidth = 1.5
    path.stroke()
    img.unlockFocus()
    img.accessibilityDescription = "None"
    return img
  }

  /// Resolve the user's preferred terminal app for the context menu. Reads
  /// `$ZEST_TERMINAL` then `$TERMINAL`; accepts a bundle id (e.g.
  /// `"com.mitchellh.ghostty"`, `"com.googlecode.iterm2"`, `"net.kovidgoyal.kitty"`)
  /// or a display name (e.g. `"Ghostty"`, `"iTerm"`). Falls back to
  /// `com.apple.Terminal`. Returns `nil` only when no candidate resolves.
  private static func resolvePreferredTerminal() -> (bundleId: String, appURL: URL)? {
    let env = ProcessInfo.processInfo.environment
    let raw = (env["ZEST_TERMINAL"] ?? env["TERMINAL"])?.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let probe = (raw?.isEmpty == false) ? raw : nil
    let ws = NSWorkspace.shared

    if let probe {
      // Bundle-id form (contains a dot) → direct lookup.
      if probe.contains(".") {
        if let url = ws.urlForApplication(withBundleIdentifier: probe) {
          return (probe, url)
        }
      }
      // Display-name form → match against running apps first (cheap, no
      // filesystem scan) before giving up. This covers the common case
      // where the user's terminal of choice is already open.
      for app in ws.runningApplications where app.localizedName == probe {
        if let id = app.bundleIdentifier,
          let url = ws.urlForApplication(withBundleIdentifier: id)
        {
          return (id, url)
        }
      }
    }

    if let url = ws.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
      return ("com.apple.Terminal", url)
    }
    return nil
  }

  private func makeItem(from r: ZestCore.Row) -> FileItem {
    let isDir = r.kind == 1
    let meta = Category.meta(kind: r.kind, category: r.category)

    let ext: String
    if isDir {
      ext = "—"
    } else if let dot = r.name.lastIndex(of: "."), dot != r.name.startIndex {
      let raw = r.name[r.name.index(after: dot)...]
      ext = raw.isEmpty ? "—" : raw.lowercased()
    } else {
      ext = "—"
    }

    let path = (r.dirPath as NSString).appendingPathComponent(r.name)

    return FileItem(
      name: r.name,
      path: path,
      dirPath: r.dirPath,
      isDirectory: isDir,
      size: r.size,
      mtime: r.mtime,
      kindLabel: meta.label,
      kindColor: meta.color,
      symbol: meta.symbol,
      symbolColor: meta.color,
      extText: ext,
      folderColor: isDir ? coordinator.userState.folderColor(forPath: path) : nil,
    )
  }

  // MARK: Empty state

  /// Build the empty-state label once; `reload()` toggles its visibility.
  /// Now means "this folder has no indexed entries" (which is fine).
  private func buildEmptyState() {
    guard emptyLabel == nil else {
      return
    }
    let label = NSTextField(labelWithString: "")
    label.font = .systemFont(ofSize: 13, weight: .regular)
    label.textColor = Theme.textSecondary
    label.alignment = .center
    label.isHidden = true
    label.usesSingleLineMode = false
    label.cell?.wraps = true
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 2
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
    ])
    emptyLabel = label
  }

  // MARK: Table

  private func buildTable() {
    tableView.dataSource = self
    tableView.delegate = self
    tableView.rowHeight = 34
    tableView.selectionHighlightStyle = .none
    tableView.usesAlternatingRowBackgroundColors = false
    tableView.backgroundColor = Theme.background
    tableView.intercellSpacing = .zero
    tableView.gridStyleMask = []
    tableView.allowsMultipleSelection = false
    tableView.allowsEmptySelection = false
    tableView.headerView = ZestTableHeaderView()
    tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

    addColumn(Self.colName, "NAME", width: 360, min: 240, max: 100_000)
    addColumn(Self.colSize, "SIZE", width: 90, min: 90, max: 90, alignment: .right)
    addColumn(Self.colMod, "MODIFIED", width: 170, min: 170, max: 170)
    addColumn(Self.colKind, "KIND", width: 120, min: 120, max: 120)
    addColumn(Self.colExt, "EXT", width: 70, min: 70, max: 70)

    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.drawsBackground = true
    scrollView.backgroundColor = Theme.background
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.automaticallyAdjustsContentInsets = false
    view.addSubview(scrollView)
    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func addColumn(
    _ id: NSUserInterfaceItemIdentifier, _ title: String,
    width: CGFloat, min: CGFloat, max: CGFloat,
    alignment: NSTextAlignment = .left,
  ) {
    let col = NSTableColumn(identifier: id)
    col.width = width
    col.minWidth = min
    col.maxWidth = max
    col.title = title
    // Header drawing is handled by ZestHeaderCell; set the styled string too.
    col.headerCell = ZestHeaderCell(textCell: title)
    (col.headerCell as? ZestHeaderCell)?.alignment = alignment
    tableView.addTableColumn(col)
  }

  /// Reflect the coordinator's active sort on the column headers: the sorted
  /// column shows a ↑/↓ glyph in `Theme.text`; others render plain.
  private func updateSortIndicator() {
    let activeID = Self.identifier(forColumn: coordinator.sortColumn)
    for col in tableView.tableColumns {
      guard let cell = col.headerCell as? ZestHeaderCell else {
        continue
      }
      if col.identifier == activeID {
        cell.sortIndicator = coordinator.sortAscending ? .ascending : .descending
      } else {
        cell.sortIndicator = .none
      }
    }
    tableView.headerView?.needsDisplay = true
  }
}

// MARK: - Data source / delegate

extension BrowserViewController: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in _: NSTableView) -> Int {
    items.count
  }

  /// Selection changes emit a status-bar summary: `"<name> — <Kind>"`, plus
  /// `" · <size>"` for files (nil when nothing is selected).
  func tableViewSelectionDidChange(_: Notification) {
    pushSelectionSummary()
  }

  /// 48pt two-line rows in search mode, 34pt single-line rows when browsing.
  func tableView(_: NSTableView, heightOfRow _: Int) -> CGFloat {
    searchMode ? 48 : 34
  }

  /// Header clicks drive the client-side sort: clicking the active column flips
  /// direction, clicking another column switches to it (ascending). The
  /// coordinator's `onChange` triggers a reload through RootViewController.
  func tableView(_: NSTableView, didClick tableColumn: NSTableColumn) {
    guard let col = Self.sortColumn(forID: tableColumn.identifier) else {
      return
    }
    if coordinator.sortColumn == col {
      coordinator.sortAscending.toggle()
    } else {
      coordinator.sortColumn = col
      coordinator.sortAscending = true
    }
  }

  private static func sortColumn(forID id: NSUserInterfaceItemIdentifier) -> AppCoordinator
    .SortColumn?
  {
    switch id {
    case colName:
      .name
    case colSize:
      .size
    case colMod:
      .modified
    case colKind:
      .kind
    case colExt:
      .ext
    default:
      nil
    }
  }

  private static func identifier(forColumn column: AppCoordinator.SortColumn)
    -> NSUserInterfaceItemIdentifier
  {
    switch column {
    case .name:
      colName
    case .size:
      colSize
    case .modified:
      colMod
    case .kind:
      colKind
    case .ext:
      colExt
    }
  }

  func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
    let id = NSUserInterfaceItemIdentifier("FileRowView")
    return (tableView.makeView(withIdentifier: id, owner: self) as? FileRowView)
      ?? {
        let r = FileRowView()
        r.identifier = id
        return r
      }()
  }

  func tableView(_: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard let tableColumn, row < items.count else {
      return nil
    }
    let item = items[row]
    let id = tableColumn.identifier

    switch id {
    case BrowserViewController.colName:
      let cell = dequeueName()
      cell.configure(item, searchMode: searchMode)
      return cell
    case BrowserViewController.colMod:
      let cell = dequeueLabel(id, alignment: .left, leading: 0, trailing: 12)
      cell.label.attributedStringValue = ModifiedCell.attributed(
        iso: item.isoDate, ago: item.agoText,
      )
      return cell
    case BrowserViewController.colKind:
      let cell = dequeueKind()
      cell.configure(label: item.kindLabel, color: item.kindColor)
      return cell
    case BrowserViewController.colSize:
      let cell = dequeueLabel(id, alignment: .right, leading: 0, trailing: 10)
      cell.label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
      cell.label.textColor = Theme.textSecondary
      cell.label.alignment = .right
      cell.label.stringValue = item.sizeText
      return cell
    case BrowserViewController.colExt:
      let cell = dequeueLabel(id, alignment: .left, leading: 0, trailing: 10)
      cell.label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
      cell.label.textColor = Theme.textTertiary
      cell.label.alignment = .left
      cell.label.stringValue = item.extText
      return cell
    default:
      return nil
    }
  }

  private func dequeueName() -> NameCellView {
    let id = NSUserInterfaceItemIdentifier("NameCell")
    if let v = tableView.makeView(withIdentifier: id, owner: self) as? NameCellView {
      return v
    }
    let v = NameCellView()
    v.identifier = id
    return v
  }

  private func dequeueKind() -> KindCellView {
    let id = NSUserInterfaceItemIdentifier("KindCell")
    if let v = tableView.makeView(withIdentifier: id, owner: self) as? KindCellView {
      return v
    }
    let v = KindCellView()
    v.identifier = id
    return v
  }

  private func dequeueLabel(
    _ id: NSUserInterfaceItemIdentifier, alignment _: NSTextAlignment,
    leading: CGFloat, trailing: CGFloat,
  ) -> LabelCellView {
    if let v = tableView.makeView(withIdentifier: id, owner: self) as? LabelCellView {
      return v
    }
    let v = LabelCellView(leading: leading, trailing: trailing)
    v.identifier = id
    return v
  }
}

// MARK: - Table view (dark background through to the scroller corner)

private final class ZestTableView: NSTableView {
  override var isOpaque: Bool {
    true
  }

  /// Fired on Return/Enter for the selected row; the controller opens it.
  var onActivateSelection: (() -> Void)?
  /// Builds the context menu for a right-clicked row (or nil to suppress).
  var menuForRow: ((Int) -> NSMenu?)?

  override func keyDown(with event: NSEvent) {
    // Return (36) / Enter (76) activate the selection; everything else
    // (arrow up/down selection, page keys, …) flows to AppKit.
    if event.keyCode == 36 || event.keyCode == 76 {
      onActivateSelection?()
      return
    }
    super.keyDown(with: event)
  }

  /// Build the menu against the right-clicked row so actions target it even
  /// when it differs from the current selection.
  override func menu(for event: NSEvent) -> NSMenu? {
    let point = convert(event.locationInWindow, from: nil)
    let row = row(at: point)
    guard row >= 0 else {
      return nil
    }
    return menuForRow?(row)
  }
}

// MARK: - Row view: accent-soft fill + leading rail when selected

/// Selection chrome per spec §7: rounded `accentSoft` fill (inset 6h/2v, radius 6)
/// plus a 3pt `accent` rail on the leading edge. Drawn directly — super is not
/// called — and gated on `isSelected`.
final class FileRowView: NSTableRowView {
  override var isOpaque: Bool {
    false
  }

  override var isSelected: Bool {
    didSet {
      guard isSelected != oldValue else {
        return
      }
      needsDisplay = true
      // Re-weight the name label (semibold when selected).
      for sub in subviews {
        sub.needsLayout = true
        sub.needsDisplay = true
      }
    }
  }

  override func drawBackground(in dirtyRect: NSRect) {
    Theme.background.setFill()
    dirtyRect.fill()
    drawSelection(in: dirtyRect)
  }

  /// The table uses `.none` selection style, so AppKit won't invoke this for us;
  /// we call it from `drawBackground`. Draws the accent-soft fill + leading rail.
  override func drawSelection(in _: NSRect) {
    guard isSelected else {
      return
    }
    let a = BrowserViewController.accent
    let fillRect = bounds.insetBy(dx: 6, dy: 2)
    let path = NSBezierPath(roundedRect: fillRect, xRadius: 6, yRadius: 6)
    a.accentSoft.setFill()
    path.fill()

    // 3pt rail on the leading edge.
    let rail = NSRect(x: 0, y: bounds.minY + 4, width: 3, height: bounds.height - 8)
    let railPath = NSBezierPath(roundedRect: rail, xRadius: 1.5, yRadius: 1.5)
    a.accent.setFill()
    railPath.fill()
  }
}

// MARK: - Header

/// Dark header strip behind the column titles.
private final class ZestTableHeaderView: NSTableHeaderView {
  override func draw(_ dirtyRect: NSRect) {
    Theme.background.setFill()
    bounds.fill()
    super.draw(dirtyRect)
  }
}

/// Uppercase, tracked, tertiary 11pt header cell on the dark strip. The active
/// sort column draws a ↑/↓ glyph (accent) and brightens its title.
private final class ZestHeaderCell: NSTableHeaderCell {
  enum SortIndicator {
    case none, ascending, descending
  }

  var sortIndicator: SortIndicator = .none

  private static let accent = Theme.darkAccent

  override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
    drawInterior(withFrame: cellFrame, in: controlView)
  }

  override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
    Theme.background.setFill()
    cellFrame.fill()

    let active = sortIndicator != .none
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.lineBreakMode = .byTruncatingTail
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
      .foregroundColor: active ? Theme.text : Theme.textTertiary,
      .kern: 0.8,
      .paragraphStyle: style,
    ]
    let text = (stringValue as NSString)
    let inset: CGFloat = alignment == .right ? 0 : 14
    let rect = cellFrame.insetBy(dx: 0, dy: 0).offsetBy(dx: 0, dy: 5)
    // Reserve room on the trailing side for the sort glyph when active —
    // the glyph trails the title for every alignment (a right-aligned
    // column's title hugs drawRect.maxX, so the glyph sits just past it).
    let glyphSpace: CGFloat = active ? 14 : 0
    let drawRect = NSRect(
      x: rect.minX + (alignment == .right ? 6 : inset),
      y: rect.minY,
      width: rect.width - inset - (alignment == .right ? 6 : 0) - glyphSpace,
      height: rect.height,
    )
    text.draw(in: drawRect, withAttributes: attrs)

    guard active else {
      return
    }
    let arrow = sortIndicator == .ascending ? "\u{2191}" : "\u{2193}"  // ↑ / ↓
    let arrowAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
      .foregroundColor: ZestHeaderCell.accent.accent,
    ]
    let arrowSize = (arrow as NSString).size(withAttributes: arrowAttrs)
    let glyphX: CGFloat
    if alignment == .right {
      glyphX = drawRect.maxX + 3
    } else {
      let titleWidth = min(text.size(withAttributes: attrs).width, drawRect.width)
      glyphX = min(drawRect.minX + titleWidth + 5, cellFrame.maxX - arrowSize.width - 4)
    }
    let arrowRect = NSRect(x: glyphX, y: rect.minY, width: arrowSize.width + 2, height: rect.height)
    (arrow as NSString).draw(in: arrowRect, withAttributes: arrowAttrs)
  }
}

// MARK: - Name cell (icon + label)

/// 18×18 SF Symbol tinted by category + a name label. In search mode a second
/// line shows the containing path (mono 11, `Theme.textTertiary`, middle-
/// truncated). The name weight bumps to semibold when the row is selected.
final class NameCellView: NSTableCellView {
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let pathLabel = NSTextField(labelWithString: "")

  /// Drives the icon's vertical anchoring + path-line visibility.
  private var searchMode = false
  private var rawDirPath = ""

  // Two vertical-centering modes: single-line centers the label; two-line
  // stacks name above path. We toggle which constraints are active.
  private var labelCenterY: NSLayoutConstraint!
  private var labelTop: NSLayoutConstraint!
  private var iconCenterY: NSLayoutConstraint!
  private var iconTop: NSLayoutConstraint!

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setup()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  private func setup() {
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.imageScaling = .scaleProportionallyUpOrDown

    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 13, weight: .regular)
    label.textColor = Theme.text
    label.lineBreakMode = .byTruncatingTail
    label.cell?.truncatesLastVisibleLine = true
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    pathLabel.translatesAutoresizingMaskIntoConstraints = false
    pathLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    pathLabel.textColor = Theme.textTertiary
    pathLabel.lineBreakMode = .byTruncatingMiddle
    pathLabel.cell?.truncatesLastVisibleLine = true
    pathLabel.isHidden = true
    pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    addSubview(icon)
    addSubview(label)
    addSubview(pathLabel)
    textField = label

    labelCenterY = label.centerYAnchor.constraint(equalTo: centerYAnchor)
    labelTop = label.topAnchor.constraint(equalTo: topAnchor, constant: 7)
    iconCenterY = icon.centerYAnchor.constraint(equalTo: centerYAnchor)
    iconTop = icon.topAnchor.constraint(equalTo: topAnchor, constant: 8)

    NSLayoutConstraint.activate([
      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      icon.widthAnchor.constraint(equalToConstant: 18),
      icon.heightAnchor.constraint(equalToConstant: 18),

      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 11),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),

      pathLabel.leadingAnchor.constraint(equalTo: label.leadingAnchor),
      pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      pathLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
    ])
    applyLayoutMode()
  }

  func configure(_ item: FileItem, searchMode: Bool) {
    let img = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.kindLabel)
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    icon.image = img?.withSymbolConfiguration(config)
    icon.contentTintColor = item.folderColor ?? item.symbolColor
    label.stringValue = item.name
    rawDirPath = item.dirPath

    if self.searchMode != searchMode {
      self.searchMode = searchMode
      applyLayoutMode()
    }
    if searchMode {
      pathLabel.isHidden = false
      pathLabel.stringValue = Self.condensePath(item.dirPath)
      pathLabel.toolTip = item.dirPath
    } else {
      pathLabel.isHidden = true
      pathLabel.toolTip = nil
    }
  }

  /// Switch between single-line (centered) and two-line (stacked) layouts.
  private func applyLayoutMode() {
    if searchMode {
      labelCenterY.isActive = false
      iconCenterY.isActive = false
      labelTop.isActive = true
      iconTop.isActive = true
    } else {
      labelTop.isActive = false
      iconTop.isActive = false
      labelCenterY.isActive = true
      iconCenterY.isActive = true
    }
  }

  /// Condense a long absolute path to `first/…/lastTwo` so the meaningful head
  /// (the project root) and the leaf folders survive. `.byTruncatingMiddle` on
  /// the label handles the final pixel-level fit; this keeps the string short
  /// and semantic to begin with. Short paths pass through unchanged.
  static func condensePath(_ path: String) -> String {
    let parts = path.split(separator: "/").map(String.init)
    guard parts.count > 4 else {
      return path
    }
    let head = parts[0]
    let tail = parts.suffix(2).joined(separator: "/")
    return "\(head)/…/\(tail)"
  }

  override var backgroundStyle: NSView.BackgroundStyle {
    didSet {
      applyWeight()
    }
  }

  private func applyWeight() {
    let selected = (superview as? FileRowView)?.isSelected ?? false
    label.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
  }

  override func viewWillDraw() {
    super.viewWillDraw()
    applyWeight()
  }
}

// MARK: - Kind cell (dot + label)

/// 7×7 rounded dot in the category color + an 11.5pt label.
final class KindCellView: NSTableCellView {
  private let dot = DotView()
  private let label = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setup()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  private func setup() {
    dot.translatesAutoresizingMaskIntoConstraints = false
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = .systemFont(ofSize: 11.5, weight: .regular)
    label.textColor = Theme.textSecondary
    label.lineBreakMode = .byTruncatingTail

    addSubview(dot)
    addSubview(label)
    textField = label

    NSLayoutConstraint.activate([
      dot.leadingAnchor.constraint(equalTo: leadingAnchor),
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 7),
      dot.heightAnchor.constraint(equalToConstant: 7),

      label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  func configure(label text: String, color: NSColor) {
    label.stringValue = text
    dot.color = color
    dot.needsDisplay = true
  }
}

/// A small rounded-rect color swatch.
final class DotView: NSView {
  var color: NSColor = .gray
  override var wantsUpdateLayer: Bool {
    false
  }

  override func draw(_: NSRect) {
    let p = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
    color.setFill()
    p.fill()
  }
}

// MARK: - Modified cell (ISO date + dim relative)

/// Builds the two-color attributed string `2026-01-01 · 5mo ago`.
enum ModifiedCell {
  static func attributed(iso: String, ago: String) -> NSAttributedString {
    let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    let s = NSMutableAttributedString()
    s.append(
      NSAttributedString(
        string: iso,
        attributes: [
          .font: mono, .foregroundColor: Theme.textSecondary,
        ],
      ),
    )
    s.append(
      NSAttributedString(
        string: "  ·  \(ago)",
        attributes: [
          .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
          .foregroundColor: Theme.textTertiary,
        ],
      ),
    )
    return s
  }
}

// MARK: - Single-label cell used for Size / Modified / Ext columns

/// A vertically-centered label with explicit leading/trailing insets, laid out
/// with Auto Layout so right-aligned columns keep their breathing room.
final class LabelCellView: NSTableCellView {
  let label = NSTextField(labelWithString: "")

  init(leading: CGFloat, trailing: CGFloat) {
    super.init(frame: .zero)
    label.translatesAutoresizingMaskIntoConstraints = false
    label.lineBreakMode = .byTruncatingTail
    label.cell?.truncatesLastVisibleLine = true
    label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    label.textColor = Theme.textSecondary
    addSubview(label)
    textField = label
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailing),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }
}
