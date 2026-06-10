import AppKit

/// The filter band (42pt) below the toolbar. Layout (14pt insets, ~10pt gaps):
/// `[ScopeControl]  [chips area — empty this phase]  [flexible spacer]
///  [result count]  [SortButton]`. Mirrors the prototype's `.filterbar`.
///
/// `refresh()` reads the coordinator: which scope is selected, the result count
/// (items vs results depending on `isSearchMode`), and the active sort label.
final class FilterBarView: NSView {
  private let coordinator: AppCoordinator

  private let scopeControl: ScopeControl
  private let countLabel = NSTextField(labelWithString: "")
  private let sortButton: SortLabelButton

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    self.scopeControl = ScopeControl(coordinator: coordinator)
    self.sortButton = SortLabelButton()

    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = Theme.panel.cgColor

    countLabel.translatesAutoresizingMaskIntoConstraints = false
    countLabel.lineBreakMode = .byClipping
    countLabel.setContentHuggingPriority(.required, for: .horizontal)
    countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    addSubview(scopeControl)
    addSubview(countLabel)
    addSubview(sortButton)

    NSLayoutConstraint.activate([
      scopeControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      scopeControl.centerYAnchor.constraint(equalTo: centerYAnchor),

      // count + sort hug the trailing edge; the gap between scope and count
      // is the flexible spacer (chips would live there in a later phase).
      countLabel.trailingAnchor.constraint(equalTo: sortButton.leadingAnchor, constant: -10),
      countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      countLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: scopeControl.trailingAnchor, constant: 10),

      sortButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      sortButton.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    refresh()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) not used")
  }

  /// Re-read coordinator state: selected scope segment, the count label (which
  /// runs the query once to count rows), and the sort label.
  func refresh() {
    scopeControl.refresh()
    sortButton.update(column: coordinator.sortColumn, ascending: coordinator.sortAscending)
    updateCount()
  }

  private func updateCount() {
    let n = coordinator.results().count
    let noun =
      coordinator.isSearchMode ? (n == 1 ? "result" : "results") : (n == 1 ? "item" : "items")
    // A capped result set renders as "2,000+" — the engine stopped early.
    let countText = coordinator.resultsCapped ? "\(n)+" : "\(n)"
    let s = NSMutableAttributedString()
    s.append(
      NSAttributedString(
        string: countText,
        attributes: [
          .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
          .foregroundColor: Theme.textSecondary,
        ]))
    s.append(
      NSAttributedString(
        string: " \(noun)",
        attributes: [
          .font: NSFont.systemFont(ofSize: 12, weight: .regular),
          .foregroundColor: Theme.textTertiary,
        ]))
    countLabel.attributedStringValue = s
  }
}

// MARK: - Scope control

/// A custom 3-segment control: "This folder" / "Subfolders" / "Everywhere".
/// Matches the prototype's `.scope`: `Theme.background` track, `Theme.border`,
/// 2pt padding; the selected segment is `Theme.panelElevated` with a 1px inset
/// border + accent-tinted leading SF Symbol.
private final class ScopeControl: NSView {
  private let coordinator: AppCoordinator
  private var segments: [Segment] = []

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 7
    layer?.borderWidth = 1
    layer?.backgroundColor = Theme.background.cgColor
    layer?.borderColor = Theme.border.cgColor

    let defs: [(AppCoordinator.Scope, String, String)] = [
      (.folder, "This folder", "folder"),
      (.subfolders, "Subfolders", "folder.badge.gearshape"),
      (.everywhere, "Everywhere", "globe"),
    ]
    for (scope, title, symbol) in defs {
      let seg = Segment(title: title, symbol: symbol) {
        [weak self] in
        self?.coordinator.scope = scope  // fires onChange → filterBar.refresh()
      }
      seg.scope = scope
      segments.append(seg)
    }

    let stack = NSStackView(views: segments)
    stack.orientation = .horizontal
    stack.spacing = 2
    stack.alignment = .centerY
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
      stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError()
  }

  func refresh() {
    for seg in segments {
      seg.setSelected(seg.scope == coordinator.scope)
    }
  }

  /// One segment button.
  final class Segment: NSView {
    var scope: AppCoordinator.Scope = .folder
    private let onClick: () -> Void
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private static let accent = Theme.deriveAccent(base: Theme.defaultAccentBase, theme: .dark)
    private var selected = false

    init(title: String, symbol: String, onClick: @escaping () -> Void) {
      self.onClick = onClick
      super.init(frame: .zero)
      translatesAutoresizingMaskIntoConstraints = false
      wantsLayer = true
      layer?.cornerRadius = 5

      let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
      icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
        .withSymbolConfiguration(cfg)
      icon.contentTintColor = Theme.textSecondary
      icon.imageScaling = .scaleProportionallyDown
      icon.translatesAutoresizingMaskIntoConstraints = false

      label.stringValue = title
      label.font = .systemFont(ofSize: 11.5, weight: .regular)
      label.textColor = Theme.textSecondary
      label.translatesAutoresizingMaskIntoConstraints = false

      let stack = NSStackView(views: [icon, label])
      stack.orientation = .horizontal
      stack.spacing = 5
      stack.alignment = .centerY
      stack.translatesAutoresizingMaskIntoConstraints = false
      addSubview(stack)
      NSLayoutConstraint.activate([
        heightAnchor.constraint(equalToConstant: 24),
        stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
        stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 12),
        icon.heightAnchor.constraint(equalToConstant: 12),
      ])
    }

    required init?(coder: NSCoder) {
      fatalError()
    }

    func setSelected(_ value: Bool) {
      selected = value
      if value {
        layer?.backgroundColor = Theme.panelElevated.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.border.cgColor
        label.textColor = Theme.text
        icon.contentTintColor = Segment.accent.accent
      } else {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        label.textColor = Theme.textSecondary
        icon.contentTintColor = Theme.textSecondary
      }
    }

    override func mouseDown(with event: NSEvent) {
      let up = window?.nextEvent(matching: [.leftMouseUp])
      if let up, bounds.contains(convert(up.locationInWindow, from: nil)) {
        onClick()
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
        owner: self, userInfo: nil)
      addTrackingArea(t)
      tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
      guard !selected else {
        return
      }
      label.textColor = Theme.text
    }

    override func mouseExited(with event: NSEvent) {
      guard !selected else {
        return
      }
      label.textColor = Theme.textSecondary
    }
  }
}

// MARK: - Sort label button (display-only)

/// A small display-only button showing the active sort, e.g. "Name ↑". The real
/// sort interaction lives on the table column headers; this just reflects state.
private final class SortLabelButton: NSView {
  private let icon = NSImageView()
  private let label = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 6

    let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
    icon.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort")?
      .withSymbolConfiguration(cfg)
    icon.contentTintColor = Theme.textSecondary
    icon.imageScaling = .scaleProportionallyDown
    icon.translatesAutoresizingMaskIntoConstraints = false

    label.font = .systemFont(ofSize: 12, weight: .regular)
    label.textColor = Theme.textSecondary
    label.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [icon, label])
    stack.orientation = .horizontal
    stack.spacing = 6
    stack.alignment = .centerY
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 26),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      icon.widthAnchor.constraint(equalToConstant: 12),
      icon.heightAnchor.constraint(equalToConstant: 12),
    ])
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  required init?(coder: NSCoder) {
    fatalError()
  }

  func update(column: AppCoordinator.SortColumn, ascending: Bool) {
    let name: String
    switch column {
    case .name:
      name = "Name"
    case .size:
      name = "Size"
    case .modified:
      name = "Modified"
    case .kind:
      name = "Kind"
    case .ext:
      name = "Ext"
    }
    label.stringValue = "\(name) \(ascending ? "↑": "↓")"
  }
}
