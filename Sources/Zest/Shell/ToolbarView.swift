import AppKit

/// The real toolbar band (56pt): back / forward / up nav buttons, an editable
/// breadcrumb, a flexible search field, and a "Saved ▾" button that toggles
/// the in-window saved-filters card (owned by RootViewController).
/// Leading inset 88 clears the traffic lights; trailing inset 14.
final class ToolbarView: NSView {
  private let coordinator: AppCoordinator

  private let backButton: IconButton
  private let forwardButton: IconButton
  private let upButton: IconButton
  private let breadcrumb: Breadcrumb
  private let searchField: SearchField
  private let savedButton: PillButton
  private var navStack: NSStackView!

  /// Fired by the Saved button; RootViewController toggles the card.
  var onSavedClick: (() -> Void)?
  /// Exposed so the card's dismissal monitor can exclude the toggle button.
  var savedButtonView: NSView { savedButton }
  /// Exposed for the outside-click blur monitor's hit test.
  var searchFieldView: NSView { searchField }
  var isSearchEditing: Bool { searchField.isEditing }

  /// ⌘F: put the caret in the search field.
  func focusSearch() { searchField.focus() }

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    self.backButton = IconButton(symbol: "chevron.left", help: "Back")
    self.forwardButton = IconButton(symbol: "chevron.right", help: "Forward")
    self.upButton = IconButton(symbol: "arrow.up", help: "Enclosing folder")
    self.breadcrumb = Breadcrumb(coordinator: coordinator)
    self.searchField = SearchField(coordinator: coordinator)
    self.savedButton = PillButton(
      title: "Saved", leadingSymbol: "bookmark", trailingSymbol: "chevron.down")

    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = Theme.panel.cgColor

    backButton.onClick = { [weak coordinator] in coordinator?.goBack() }
    forwardButton.onClick = { [weak coordinator] in coordinator?.goForward() }
    upButton.onClick = { [weak coordinator] in coordinator?.goUp() }
    savedButton.onClick = { [weak self] in self?.onSavedClick?() }

    navStack = NSStackView(views: [backButton, forwardButton, upButton])
    navStack.orientation = .horizontal
    navStack.spacing = 2
    navStack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(navStack)
    addSubview(breadcrumb)
    addSubview(searchField)
    addSubview(savedButton)

    NSLayoutConstraint.activate([
      navStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 88),
      navStack.centerYAnchor.constraint(equalTo: centerYAnchor),

      breadcrumb.leadingAnchor.constraint(equalTo: navStack.trailingAnchor, constant: 12),
      breadcrumb.centerYAnchor.constraint(equalTo: centerYAnchor),

      // Search sits after a flexible gap from the breadcrumb, then the
      // saved pill pins to the trailing edge.
      searchField.leadingAnchor.constraint(
        greaterThanOrEqualTo: breadcrumb.trailingAnchor, constant: 10),
      searchField.trailingAnchor.constraint(equalTo: savedButton.leadingAnchor, constant: -10),
      searchField.centerYAnchor.constraint(equalTo: centerYAnchor),

      savedButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      savedButton.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])

    // Width policy: the breadcrumb hugs its crumbs (equality inside the
    // control), the search field aims for a fixed preferred width, and the
    // `>=` gap between them absorbs ALL remaining slack — an explicit spacer,
    // so neither control stretches on resize/fullscreen and clicks in the
    // gap hit inert toolbar chrome. On narrow windows the search compresses
    // to its 200pt minimum first, then the breadcrumb truncates.
    let preferred = searchField.widthAnchor.constraint(equalToConstant: 360)
    preferred.priority = NSLayoutConstraint.Priority(500)
    preferred.isActive = true
    searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
    // The breadcrumb compresses before the search field shrinks below its min.
    breadcrumb.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    refresh()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

  /// Feed the breadcrumb the width it may occupy so it can middle-collapse
  /// deep paths: everything between the nav cluster and the search field at
  /// its 200pt minimum. The breadcrumb only reacts to real changes, so this
  /// can't feed back into layout.
  override func layout() {
    super.layout()
    // No fixed ceiling: long paths may use all the slack between the nav
    // cluster and the search field at its 200pt minimum. The breadcrumb
    // hugs its content, so short paths don't stretch.
    let available =
      (savedButton.frame.minX - 10 - 200 - 10) - (navStack.frame.maxX + 12)
    breadcrumb.availableWidth = max(120, available)
  }

  /// Update enabled/disabled state for back/forward, the breadcrumb display, and
  /// the search field (which clears itself when navigation reset the query).
  func refresh() {
    backButton.setEnabled(coordinator.canGoBack)
    forwardButton.setEnabled(coordinator.canGoForward)
    breadcrumb.refresh()
    searchField.refresh()
  }
}

// MARK: - Pill button (Saved ▾)

/// A styled pill matching the prototype's `.toolbtn`: 34pt, `Theme.panel` fill,
/// `Theme.border` border, `Theme.textSecondary` text, optional leading/trailing
/// SF Symbols. Hover brightens text + accent-tinted border. For this phase the
/// Saved button is a render-only stub.
final class PillButton: NSView {
  var onClick: (() -> Void)?
  private static let accent = Theme.darkAccent

  private let leadingIcon = NSImageView()
  private let label = NSTextField(labelWithString: "")
  private let trailingIcon = NSImageView()

  init(title: String, leadingSymbol: String?, trailingSymbol: String?) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    layer?.backgroundColor = Theme.panel.cgColor
    layer?.borderColor = Theme.border.cgColor

    let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
    leadingIcon.image = leadingSymbol.flatMap {
      NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }
    trailingIcon.image = trailingSymbol.flatMap {
      NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }
    for iv in [leadingIcon, trailingIcon] {
      iv.contentTintColor = Theme.textSecondary
      iv.imageScaling = .scaleProportionallyDown
      iv.translatesAutoresizingMaskIntoConstraints = false
    }

    label.stringValue = title
    label.font = .systemFont(ofSize: 12.5, weight: .regular)
    label.textColor = Theme.textSecondary
    label.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [leadingIcon, label, trailingIcon])
    stack.orientation = .horizontal
    stack.spacing = 7
    stack.alignment = .centerY
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 34),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      leadingIcon.widthAnchor.constraint(equalToConstant: 13),
      leadingIcon.heightAnchor.constraint(equalToConstant: 13),
      trailingIcon.widthAnchor.constraint(equalToConstant: 11),
      trailingIcon.heightAnchor.constraint(equalToConstant: 11),
    ])
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.required, for: .horizontal)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func mouseDown(with event: NSEvent) {
    let up = window?.nextEvent(matching: [.leftMouseUp])
    if let up, bounds.contains(convert(up.locationInWindow, from: nil)) { onClick?() }
  }

  private var tracking: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = tracking { removeTrackingArea(t) }
    let t = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(t)
    tracking = t
  }
  override func mouseEntered(with event: NSEvent) {
    guard isTopmostUnderMouse else { return }
    layer?.backgroundColor = Theme.hover.cgColor
    layer?.borderColor = PillButton.accent.accentLine.cgColor
    label.textColor = Theme.text
    leadingIcon.contentTintColor = Theme.text
    trailingIcon.contentTintColor = Theme.text
  }
  override func mouseExited(with event: NSEvent) {
    layer?.backgroundColor = Theme.panel.cgColor
    layer?.borderColor = Theme.border.cgColor
    label.textColor = Theme.textSecondary
    leadingIcon.contentTintColor = Theme.textSecondary
    trailingIcon.contentTintColor = Theme.textSecondary
  }
}

// MARK: - Icon button

/// A 28×28 borderless, layer-backed button rendering an SF Symbol in
/// `Theme.textSecondary`, with a `Theme.hover` rounded background on hover.
/// When disabled it dims to 0.35 alpha and stops accepting clicks.
final class IconButton: NSView {
  var onClick: (() -> Void)?

  private let imageView = NSImageView()
  private var enabled = true
  private var hovering = false

  init(symbol: String, help: String) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 6
    toolTip = help

    let img = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
    let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    imageView.image = img?.withSymbolConfiguration(config)
    imageView.contentTintColor = Theme.textSecondary
    imageView.imageScaling = .scaleProportionallyDown
    imageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)

    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 28),
      heightAnchor.constraint(equalToConstant: 28),
      imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      imageView.widthAnchor.constraint(equalToConstant: 16),
      imageView.heightAnchor.constraint(equalToConstant: 16),
    ])
  }
  required init?(coder: NSCoder) { fatalError() }

  func setEnabled(_ value: Bool) {
    guard value != enabled else { return }
    enabled = value
    alphaValue = value ? 1.0 : 0.35
    if !value {
      hovering = false
      layer?.backgroundColor = NSColor.clear.cgColor
    }
  }

  override func mouseDown(with event: NSEvent) {
    guard enabled else { return }
    // Confirm the mouse-up lands inside before firing (standard button feel).
    let up = window?.nextEvent(matching: [.leftMouseUp])
    if let up, bounds.contains(convert(up.locationInWindow, from: nil)) {
      onClick?()
    }
  }

  private var tracking: NSTrackingArea?
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = tracking { removeTrackingArea(t) }
    let t = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(t)
    tracking = t
  }

  override func mouseEntered(with event: NSEvent) {
    guard isTopmostUnderMouse else { return }
    guard enabled else { return }
    hovering = true
    layer?.backgroundColor = Theme.hover.cgColor
    imageView.contentTintColor = Theme.text
  }

  override func mouseExited(with event: NSEvent) {
    hovering = false
    layer?.backgroundColor = NSColor.clear.cgColor
    imageView.contentTintColor = Theme.textSecondary
  }
}
