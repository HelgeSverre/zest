import AppKit

/// Sidebar with two sections: PINNED folders and CATEGORIES tree.
/// The categories tree is scope-aware: it histograms the current folder
/// (or sub-tree when scope is Subfolders/Everywhere) and shows extension
/// drill-downs. Clicking a category injects `cat:<key>` into the query;
/// clicking an extension injects `cat:<key> ext:<ext>`.
final class SidebarViewController: NSViewController {
  private let coordinator: AppCoordinator
  private var pinRows: [PinRow] = []
  private var categorySection: CategorySection?

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) not used")
  }

  private struct Pin {
    let label: String
    let symbol: String
    let path: String
  }

  private func pins() -> [Pin] {
    coordinator.userState.pins.map { p in
      Pin(label: p.name, symbol: Self.pinSymbol(for: p), path: p.path)
    }
  }

  private static func pinSymbol(for pin: UserState.Pin) -> String {
    switch pin.name {
    case "Home": "house"
    case "Desktop": "display"
    case "Documents": "doc"
    case "Downloads": "arrow.down"
    default: "folder"
    }
  }

  override func loadView() {
    let v = NSView()
    v.wantsLayer = true
    v.layer?.backgroundColor = Theme.panel.withAlphaComponent(0.6).cgColor
    view = v
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false

    // ── PINNED ──
    let pinnedHeader = makeHeader("PINNED")
    stack.addArrangedSubview(pinnedHeader)
    stack.setCustomSpacing(8, after: pinnedHeader)

    for pin in pins() {
      let row = PinRow(label: pin.label, symbol: pin.symbol, path: pin.path) {
        [weak self] path in
        if self?.coordinator.navigate(to: path) == false { NSSound.beep() }
      }
      stack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      pinRows.append(row)
    }

    // ── CATEGORIES ──
    let catHeader = makeHeader("CATEGORIES")
    stack.setCustomSpacing(18, after: pinRows.last!)
    stack.addArrangedSubview(catHeader)
    stack.setCustomSpacing(8, after: catHeader)

    let catSection = CategorySection(coordinator: coordinator, widthProvider: stack)
    categorySection = catSection
    stack.addArrangedSubview(catSection)
    catSection.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
    ])

    refresh()
  }

  private func makeHeader(_ text: String) -> NSTextField {
    let header = NSTextField(labelWithString: text)
    header.font = .systemFont(ofSize: 10.5, weight: .semibold)
    header.textColor = Theme.textTertiary
    header.translatesAutoresizingMaskIntoConstraints = false
    header.attributedStringValue = NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
        .foregroundColor: Theme.textTertiary,
        .kern: 0.95,
      ],
    )
    return header
  }

  /// Update active-pin highlight + trigger a background histogram recomputation.
  func refresh() {
    let current = coordinator.currentPath
    for row in pinRows {
      row.setActive(row.path == current)
    }
    categorySection?.refresh()
  }
}

// MARK: - Category Section

/// Holds the header and the dynamically-built category rows.
private final class CategorySection: NSView {
  private let coordinator: AppCoordinator
  private let widthProvider: NSView
  private var rows: [NSView] = []
  private let stack = NSStackView()

  /// Category indices the user has explicitly expanded via the chevron.
  /// Persists across refreshes (lives on the long-lived section view). Active
  /// categories are also auto-expanded regardless of this set, so selecting a
  /// category always shows its extensions on first render.
  private var expandedIndices: Set<Int> = []

  /// Last computed histogram; used to re-render rows after a chevron toggle
  /// or a filter-only change without re-running the background index query.
  private var lastHistogram: Histogram?

  /// (path, scope, index) of the histogram currently in `lastHistogram`. The
  /// next `refresh()` only re-walks the index if this key changed, so per-
  /// keystroke text updates just re-render the cached rows with the new active
  /// state. The `index` component detects daemon hot-swaps (new inode/mtime)
  /// when path+scope are unchanged — including the launch-before-first-index
  /// case where core was nil, so an all-zeros histogram never sticks.
  private var lastRefreshKey: (path: String, scope: AppCoordinator.Scope, index: ZestCore.FileIdentity?)?

  /// Histogram generation counter (owned by sidebar, passed here implicitly via refresh).
  private var histogramGeneration = 0

  init(coordinator: AppCoordinator, widthProvider: NSView) {
    self.coordinator = coordinator
    self.widthProvider = widthProvider
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  /// Recompute the histogram in the background when the folder context
  /// (path or scope) changes; otherwise just re-render with the cached
  /// `lastHistogram` so the active state stays in sync with `coordinator.filter`.
  ///
  /// Both the category counts and the per-category ext breakdown come from
  /// the indexer's precomputed columns (O(1) for `.folder`, O(D) for the
  /// subtree merge). The previous implementation walked all rows in Swift to
  /// build ext lists; the v3 ext_breakdown column kills that walk entirely.
  func refresh() {
    let path = coordinator.currentPath
    let scope = coordinator.scope
    let index = coordinator.core?.fileIdentity

    if let cached = lastHistogram,
      lastRefreshKey?.path == path,
      lastRefreshKey?.scope == scope,
      lastRefreshKey?.index == index
    {
      // Folder context and index identity unchanged: just re-render so active
      // highlights track the latest `coordinator.filter`.
      rebuildRows(with: cached)
      return
    }
    lastRefreshKey = (path: path, scope: scope, index: index)

    histogramGeneration += 1
    let gen = histogramGeneration
    let core = coordinator.core
    let root = coordinator.scopeRoot
    let depth = coordinator.scopeDepth

    DispatchQueue.global(qos: .userInitiated).async {
      [weak self] in
      guard let self else {
        return
      }
      // O(1) category counts from the indexer's precomputed histogram.
      let catCounts =
        core?.histogram(scope: root, maxDepth: depth)
        ?? Array(repeating: 0, count: 9)
      // Per-category ext breakdown from the v3 ext_breakdown column.
      // 9 calls (one per cat), each O(1) at depth=1 / O(D) for subtree.
      let extBreakdowns: [[(name: String, count: Int)]] = (0..<9).map { cat in
        core?.extBreakdown(scope: root, maxDepth: depth, cat: UInt8(cat), max: 16) ?? []
      }
      let histogram = Self.buildHistogram(
        catCounts: catCounts,
        extBreakdowns: extBreakdowns
      )

      DispatchQueue.main.async {
        guard self.histogramGeneration == gen else {
          return
        }
        self.lastHistogram = histogram
        self.rebuildRows(with: histogram)
      }
    }
  }

  private func rebuildRows(with histogram: Histogram) {
    // Remove old rows.
    for row in rows {
      row.removeFromSuperview()
    }
    rows.removeAll()

    let activeCat = coordinator.filter.category
    let activeExt = coordinator.filter.extensions.first

    for entry in histogram.categories {
      let meta = Category.meta(category: entry.index)
      let isActive = activeCat == meta.queryKey
      let hasChildren = entry.extensions.count > 1
      // Active categories auto-expand; manually-toggled ones stay open across refreshes.
      let isExpanded = hasChildren && (expandedIndices.contains(entry.index) || isActive)

      let row = CatRow(
        meta: meta,
        count: entry.count,
        isExpanded: isExpanded,
        hasChildren: hasChildren,
        isActive: isActive,
        onSelect: {
          [weak self] in
          guard let self else {
            return
          }
          // Toggle: re-clicking the active row clears the category,
          // preserving any extension filter and the search text.
          coordinator.filter.category = isActive ? nil : meta.queryKey
          rebuildRows(with: histogram)
        },
        onToggleExpand: {
          [weak self] in
          guard let self else {
            return
          }
          if expandedIndices.contains(entry.index) {
            expandedIndices.remove(entry.index)
          } else {
            expandedIndices.insert(entry.index)
          }
          rebuildRows(with: histogram)
        },
      )
      stack.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      rows.append(row)

      if isExpanded {
        for extEntry in entry.extensions {
          let extRow = ExtRow(
            meta: meta,
            ext: extEntry.ext,
            count: extEntry.count,
            isActive: isActive && activeExt == extEntry.ext,
            onSelect: {
              [weak self] in
              guard let self else {
                return
              }
              // Toggle: re-clicking the active ext removes it
              // from the filter, keeping the parent category set
              // and any search text intact.
              if isActive, activeExt == extEntry.ext {
                coordinator.filter.extensions.remove(extEntry.ext)
              } else {
                coordinator.filter.category = meta.queryKey
                coordinator.filter.extensions = [extEntry.ext]
              }
              rebuildRows(with: histogram)
            },
          )
          stack.addArrangedSubview(extRow)
          extRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
          rows.append(extRow)
        }
      }
    }
  }

  // MARK: Histogram builder

  // TODO: improve naming, no context about what histogram we are dealing with.

  private struct Histogram {
    // TODO: dont abbreviate, find better name

    struct CatEntry {
      let index: Int
      let count: Int
      let extensions: [ExtEntry]
    }

    // TODO: dont abbreviate, find better name

    struct ExtEntry {
      let ext: String
      let count: Int
    }

    let categories: [CatEntry]
  }

  /// Build the sidebar's Histogram from a precomputed per-category count array
  /// (from the indexer's histogram column) and precomputed per-category ext
  /// breakdowns (from the indexer's ext_breakdown column). The Zig side does
  /// all the work — no row walking on the Swift side.
  /// `catCounts` is indexed 0-8 by the `FileCategory` byte.
  /// `extBreakdowns[cat]` is the sorted-by-count top-N list for that category.
  private static func buildHistogram(
    catCounts: [Int],
    extBreakdowns: [[(name: String, count: Int)]]
  ) -> Histogram {
    // Build sorted category entries.
    let nonZeroCount = catCounts.count(where: { $0 > 0 })
    var catEntries: [Histogram.CatEntry] = []
    for (catIndex, count) in catCounts.enumerated() where count > 0 {
      // Skip "Other" (0) unless it's the only category.
      if catIndex == 0, nonZeroCount > 1 {
        continue
      }

      let exts = extBreakdowns[catIndex]
      let sortedExts = exts.map { Histogram.ExtEntry(ext: $0.name, count: $0.count) }
      catEntries.append(Histogram.CatEntry(index: catIndex, count: count, extensions: sortedExts))
    }

    catEntries.sort {
      $0.count > $1.count
    }
    return Histogram(categories: catEntries)
  }
}

// MARK: - Category row

// TODO: rename something more self explanatory
/// A 26pt category row: optional chevron, colored dot, label, right-aligned count.
private final class CatRow: NSView {
  private let onSelect: () -> Void
  private let onToggleExpand: (() -> Void)?
  private let hasChildren: Bool
  private var expanded: Bool
  private var active = false
  private var hovering = false
  private static let accent = Theme.deriveAccent(base: Theme.defaultAccentBase, theme: .dark)

  /// Leading 22pt is the chevron-only hit zone; the rest of the row selects.
  private static let chevronHitWidth: CGFloat = 22

  private let chevron = NSImageView()
  private let dot = NSView()
  private let label = NSTextField(labelWithString: "")
  private let countLabel = NSTextField(labelWithString: "")
  private let rail = NSView()

  init(
    meta: Category.Meta, count: Int, isExpanded: Bool, hasChildren: Bool,
    isActive: Bool, onSelect: @escaping () -> Void, onToggleExpand: (() -> Void)? = nil,
  ) {
    self.onSelect = onSelect
    self.onToggleExpand = onToggleExpand
    self.hasChildren = hasChildren
    expanded = isExpanded
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 6

    // Chevron
    if hasChildren {
      let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
      let symbol = isExpanded ? "chevron.down" : "chevron.right"
      chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg)
      chevron.contentTintColor = Theme.textTertiary
      chevron.imageScaling = .scaleProportionallyDown
      chevron.translatesAutoresizingMaskIntoConstraints = false
      addSubview(chevron)
    }

    // Colored dot
    dot.wantsLayer = true
    dot.layer?.backgroundColor = meta.color.cgColor
    dot.layer?.cornerRadius = 4
    dot.translatesAutoresizingMaskIntoConstraints = false
    addSubview(dot)

    // Label
    label.stringValue = meta.pluralLabel
    label.font = .systemFont(ofSize: 12.5, weight: .regular)
    label.textColor = Theme.textSecondary
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)

    // Count
    countLabel.stringValue = "\(count)"
    countLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
    countLabel.textColor = Theme.textTertiary
    countLabel.alignment = .right
    countLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(countLabel)

    // Rail
    rail.wantsLayer = true
    rail.layer?.backgroundColor = CatRow.accent.accent.cgColor
    rail.layer?.cornerRadius = 1.5
    rail.isHidden = true
    rail.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rail)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 26),

      rail.leadingAnchor.constraint(equalTo: leadingAnchor),
      rail.centerYAnchor.constraint(equalTo: centerYAnchor),
      rail.widthAnchor.constraint(equalToConstant: 3),
      rail.heightAnchor.constraint(equalToConstant: 16),

      dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hasChildren ? 22 : 8),
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 8),
      dot.heightAnchor.constraint(equalToConstant: 8),

      label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),

      countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
    ])

    if hasChildren {
      NSLayoutConstraint.activate([
        chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
        chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        chevron.widthAnchor.constraint(equalToConstant: 14),
        chevron.heightAnchor.constraint(equalToConstant: 14),
      ])
    }

    setActive(isActive)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  func setActive(_ value: Bool) {
    active = value
    rail.isHidden = !value
    label.textColor = value ? Theme.text : Theme.textSecondary
    updateBackground()
  }

  private func updateBackground() {
    if active {
      layer?.backgroundColor = CatRow.accent.accentSoft.cgColor
    } else if hovering {
      layer?.backgroundColor = Theme.hover.cgColor
    } else {
      layer?.backgroundColor = NSColor.clear.cgColor
    }
  }

  override func mouseDown(with _: NSEvent) {
    let up = window?.nextEvent(matching: [.leftMouseUp])
    guard let up, bounds.contains(convert(up.locationInWindow, from: nil)) else {
      return
    }
    let local = convert(up.locationInWindow, from: nil)
    // Leading chevron zone toggles expansion only; the rest of the row selects.
    if hasChildren, local.x < Self.chevronHitWidth, let toggle = onToggleExpand {
      toggle()
    } else {
      onSelect()
    }
  }

  private var tracking: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = tracking {
      removeTrackingArea(t)
    }
    let t = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
      owner: self, userInfo: nil,
    )
    addTrackingArea(t)
    tracking = t
  }

  override func mouseEntered(with _: NSEvent) {
    hovering = true
    updateBackground()
  }

  override func mouseExited(with _: NSEvent) {
    hovering = false
    updateBackground()
  }
}

// MARK: - Extension row

// TODO: rename better
/// A 22pt indented extension row under a category. "• .zig  2"
private final class ExtRow: NSView {
  private let onSelect: () -> Void
  private var active = false
  private var hovering = false
  private static let accent = Theme.deriveAccent(base: Theme.defaultAccentBase, theme: .dark)

  private let dot = NSView()
  private let label = NSTextField(labelWithString: "")
  private let countLabel = NSTextField(labelWithString: "")
  private let rail = NSView()

  init(meta: Category.Meta, ext: String, count: Int, isActive: Bool, onSelect: @escaping () -> Void)
  {
    self.onSelect = onSelect
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 6

    dot.wantsLayer = true
    dot.layer?.backgroundColor = meta.color.withAlphaComponent(0.55).cgColor
    dot.layer?.cornerRadius = 3
    dot.translatesAutoresizingMaskIntoConstraints = false
    addSubview(dot)

    label.stringValue = ".\(ext)"
    label.font = .systemFont(ofSize: 11.5, weight: .regular)
    label.textColor = Theme.textSecondary
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)

    countLabel.stringValue = "\(count)"
    countLabel.font = .systemFont(ofSize: 11, weight: .regular)
    countLabel.textColor = Theme.textTertiary
    countLabel.alignment = .right
    countLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(countLabel)

    rail.wantsLayer = true
    rail.layer?.backgroundColor = ExtRow.accent.accent.cgColor
    rail.layer?.cornerRadius = 1.5
    rail.isHidden = true
    rail.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rail)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 22),

      rail.leadingAnchor.constraint(equalTo: leadingAnchor),
      rail.centerYAnchor.constraint(equalTo: centerYAnchor),
      rail.widthAnchor.constraint(equalToConstant: 3),
      rail.heightAnchor.constraint(equalToConstant: 12),

      dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
      dot.centerYAnchor.constraint(equalTo: centerYAnchor),
      dot.widthAnchor.constraint(equalToConstant: 6),
      dot.heightAnchor.constraint(equalToConstant: 6),

      label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),

      countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 6),
    ])

    setActive(isActive)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  func setActive(_ value: Bool) {
    active = value
    rail.isHidden = !value
    label.textColor = value ? Theme.text : Theme.textSecondary
    updateBackground()
  }

  private func updateBackground() {
    if active {
      layer?.backgroundColor = ExtRow.accent.accentSoft.cgColor
    } else if hovering {
      layer?.backgroundColor = Theme.hover.cgColor
    } else {
      layer?.backgroundColor = NSColor.clear.cgColor
    }
  }

  override func mouseDown(with _: NSEvent) {
    let up = window?.nextEvent(matching: [.leftMouseUp])
    if let up, bounds.contains(convert(up.locationInWindow, from: nil)) {
      onSelect()
    }
  }

  private var tracking: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = tracking {
      removeTrackingArea(t)
    }
    let t = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
      owner: self, userInfo: nil,
    )
    addTrackingArea(t)
    tracking = t
  }

  override func mouseEntered(with _: NSEvent) {
    hovering = true
    updateBackground()
  }

  override func mouseExited(with _: NSEvent) {
    hovering = false
    updateBackground()
  }
}

// MARK: - Pin row (unchanged from before)

// TODO: rename to "pinned" something.
/// A 30pt-tall pin row: SF Symbol + label, rounded `Theme.hover` background on
/// hover, and (when active) the `accentSoft` fill + 3pt accent leading rail.
private final class PinRow: NSView {
  let path: String
  private let onClick: (String) -> Void
  private static let accent = Theme.deriveAccent(base: Theme.defaultAccentBase, theme: .dark)

  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let rail = NSView()
  private var active = false
  private var hovering = false

  init(label text: String, symbol: String, path: String, onClick: @escaping (String) -> Void) {
    self.path = path
    self.onClick = onClick
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 6

    let img = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    icon.image = img?.withSymbolConfiguration(config)
    icon.contentTintColor = Theme.textSecondary
    icon.imageScaling = .scaleProportionallyDown
    icon.translatesAutoresizingMaskIntoConstraints = false

    label.stringValue = text
    label.font = .systemFont(ofSize: 13, weight: .regular)
    label.textColor = Theme.textSecondary
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false

    rail.wantsLayer = true
    rail.layer?.backgroundColor = PinRow.accent.accent.cgColor
    rail.layer?.cornerRadius = 1.5
    rail.isHidden = true
    rail.translatesAutoresizingMaskIntoConstraints = false

    addSubview(rail)
    addSubview(icon)
    addSubview(label)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 30),

      rail.leadingAnchor.constraint(equalTo: leadingAnchor),
      rail.centerYAnchor.constraint(equalTo: centerYAnchor),
      rail.widthAnchor.constraint(equalToConstant: 3),
      rail.heightAnchor.constraint(equalToConstant: 18),

      icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 16),
      icon.heightAnchor.constraint(equalToConstant: 16),

      label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
      label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
      label.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  func setActive(_ value: Bool) {
    active = value
    rail.isHidden = !value
    label.textColor = value ? Theme.text : Theme.textSecondary
    icon.contentTintColor = value ? Theme.text : Theme.textSecondary
    updateBackground()
  }

  private func updateBackground() {
    if active {
      layer?.backgroundColor = PinRow.accent.accentSoft.cgColor
    } else if hovering {
      layer?.backgroundColor = Theme.hover.cgColor
    } else {
      layer?.backgroundColor = NSColor.clear.cgColor
    }
  }

  override func mouseDown(with _: NSEvent) {
    let up = window?.nextEvent(matching: [.leftMouseUp])
    if let up, bounds.contains(convert(up.locationInWindow, from: nil)) {
      onClick(path)
    }
  }

  private var tracking: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = tracking {
      removeTrackingArea(t)
    }
    let t = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
      owner: self, userInfo: nil,
    )
    addTrackingArea(t)
    tracking = t
  }

  override func mouseEntered(with _: NSEvent) {
    hovering = true
    updateBackground()
  }

  override func mouseExited(with _: NSEvent) {
    hovering = false
    updateBackground()
  }
}
