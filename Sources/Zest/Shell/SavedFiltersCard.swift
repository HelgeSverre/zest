import AppKit

/// In-window saved-filters card (prototype `.popover`): a flat panel anchored
/// top-right under the toolbar's Saved button — not an NSPopover, so there is
/// no arrow/material chrome. Lists saved filters (click to apply), plus
/// "Save current search" and "Manage filters…" actions. Mounted once by
/// RootViewController, hidden until shown.
final class SavedFiltersCard: NSView {
  private let coordinator: AppCoordinator
  private static let accent = Theme.deriveAccent(base: Theme.defaultAccentBase, theme: .dark)

  var onManage: (() -> Void)?
  var onSaveCurrent: ((String) -> Void)?
  /// The toolbar's Saved button. Its clicks pass through the dismissal
  /// monitor untouched: the button fires on mouse-UP (via `nextEvent`, which
  /// bypasses monitors), so closing on its mouse-down would make the up
  /// re-toggle the card open — a flicker instead of a toggle.
  weak var toggleExclusionView: NSView?

  private let stack = NSStackView()
  private var monitor: Any?

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = Theme.panel2.cgColor
    layer?.borderWidth = 1
    layer?.borderColor = Theme.border.cgColor
    layer?.cornerRadius = 8
    layer?.masksToBounds = false
    // ≈ --shadow-pop: 0 16px 40px -12px rgba(0,0,0,.7)
    shadow = NSShadow()
    layer?.shadowColor = NSColor.black.cgColor
    layer?.shadowOpacity = 0.6
    layer?.shadowRadius = 20
    layer?.shadowOffset = CGSize(width: 0, height: -12)
    isHidden = true

    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 0
    stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

  deinit { removeMonitor() }

  // MARK: - Show / hide

  var isShown: Bool { !isHidden }

  func toggle() {
    if isShown {
      hide()
    } else {
      show()
    }
  }

  func show() {
    reload()
    isHidden = false
    alphaValue = 0
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.14
      animator().alphaValue = 1
    }
    installMonitor()
  }

  func hide() {
    removeMonitor()
    isHidden = true
  }

  /// Dismissal mirrors the prototype's body-level mousedown: any click
  /// outside the card closes it AND still lands on its target (click-through)
  /// — an event-catcher view would swallow the click and block scrolling the
  /// list under the open card. Esc rides on the same monitor because the card
  /// never holds first responder, so responder-chain Esc can't reach it.
  private func installMonitor() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
    ) { [weak self] event in
      guard let self, self.isShown else { return event }
      if event.type == .keyDown {
        if event.keyCode == 53 {  // Esc
          self.hide()
          return nil
        }
        return event
      }
      guard event.window === self.window else { return event }
      if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
        return event
      }
      if let excluded = self.toggleExclusionView,
        excluded.bounds.contains(excluded.convert(event.locationInWindow, from: nil))
      {
        return event
      }
      self.hide()
      return event
    }
  }

  private func removeMonitor() {
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
  }

  // MARK: - Content

  /// Adds a row inset 4pt per side within the 6pt card padding.
  private func addRow(_ row: NSView, sideMargin: CGFloat = 0) {
    stack.addArrangedSubview(row)
    row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12 - sideMargin * 2)
      .isActive = true
  }

  private func reload() {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }

    addRow(makeHeader())

    let filters = coordinator.savedFilters
    if filters.isEmpty {
      let empty = CardRow(title: "No saved filters", titleColor: Theme.textTertiary)
      addRow(empty)
    } else {
      for filter in filters {
        let row = CardRow(
          title: filter.name, titleColor: Theme.text, query: filter.query
        ) { [weak self] in
          self?.hide()
          self?.coordinator.applySavedFilter(filter)
        }
        addRow(row)
      }
    }

    let sep = NSView()
    sep.translatesAutoresizingMaskIntoConstraints = false
    sep.wantsLayer = true
    sep.layer?.backgroundColor = Theme.border.cgColor
    sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
    if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(5, after: last) }
    addRow(sep, sideMargin: 4)
    stack.setCustomSpacing(5, after: sep)

    let currentQuery = coordinator.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
    if !currentQuery.isEmpty {
      let saveRow = CardRow(
        icon: "plus.circle", iconTint: SavedFiltersCard.accent.accent,
        title: "Save current search", titleColor: SavedFiltersCard.accent.accent,
        titleWeight: .medium, query: currentQuery
      ) { [weak self] in
        self?.hide()
        self?.onSaveCurrent?(currentQuery)
      }
      addRow(saveRow)
    }

    let manage = CardRow(
      icon: "gearshape", iconTint: SavedFiltersCard.accent.accentHi,
      title: "Manage filters…", titleColor: SavedFiltersCard.accent.accentHi
    ) { [weak self] in
      self?.hide()
      self?.onManage?()
    }
    addRow(manage)
  }

  private func makeHeader() -> NSView {
    let label = NSTextField(labelWithString: "")
    label.attributedStringValue = NSAttributedString(
      string: "SAVED FILTERS",
      attributes: [
        .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
        .foregroundColor: Theme.textTertiary,
        .kern: 0.84,
      ])
    label.translatesAutoresizingMaskIntoConstraints = false

    let container = NSView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
      label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
      label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
    ])
    return container
  }
}

// MARK: - Row

/// One single-line card row (prototype `.popover-item`): optional leading
/// icon, title, optional right-aligned mono query. Inert when no click
/// handler (empty state).
private final class CardRow: NSView {
  private let onClick: (() -> Void)?

  init(
    icon: String? = nil, iconTint: NSColor = Theme.textSecondary,
    title: String, titleColor: NSColor, titleWeight: NSFont.Weight = .regular,
    query: String? = nil, onClick: (() -> Void)? = nil
  ) {
    self.onClick = onClick
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 6

    var views: [NSView] = []

    if let icon {
      let iv = NSImageView()
      iv.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
      iv.contentTintColor = iconTint
      iv.translatesAutoresizingMaskIntoConstraints = false
      views.append(iv)
    }

    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = .systemFont(ofSize: 12.5, weight: titleWeight)
    titleLabel.textColor = titleColor
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    views.append(titleLabel)

    let hStack = NSStackView(views: views)
    hStack.orientation = .horizontal
    hStack.alignment = .centerY
    hStack.spacing = 8
    hStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hStack)

    var c: [NSLayoutConstraint] = [
      hStack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
      hStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
      hStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
    ]

    if let query {
      let queryLabel = NSTextField(labelWithString: query)
      queryLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
      queryLabel.textColor = Theme.textTertiary
      queryLabel.lineBreakMode = .byTruncatingTail
      queryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      queryLabel.translatesAutoresizingMaskIntoConstraints = false
      addSubview(queryLabel)
      c += [
        queryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        queryLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        queryLabel.leadingAnchor.constraint(
          greaterThanOrEqualTo: hStack.trailingAnchor, constant: 8),
      ]
    } else {
      c.append(hStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8))
    }
    NSLayoutConstraint.activate(c)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func mouseDown(with event: NSEvent) {
    guard onClick != nil else { return }
    let up = window?.nextEvent(matching: [.leftMouseUp])
    if let up, bounds.contains(convert(up.locationInWindow, from: nil)) {
      onClick?()
    }
  }

  private var tracking: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    guard onClick != nil else { return }
    if let t = tracking { removeTrackingArea(t) }
    let t = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(t)
    tracking = t
  }

  override func mouseEntered(with event: NSEvent) {
    layer?.backgroundColor = Theme.hover.cgColor
  }
  override func mouseExited(with event: NSEvent) {
    layer?.backgroundColor = NSColor.clear.cgColor
  }
}
