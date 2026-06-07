import AppKit

/// The toolbar search control (34pt, rounded): a leading magnifier, a borderless
/// text field, and a trailing clear (✕) button shown only when non-empty. Per the
/// v2 prototype's `.search`: fill `Theme.background`, border `Theme.border`,
/// radius 8; focused → accent ring (`accentLine` border + `accentSoft` glow).
///
/// On text change it debounces ~150ms, then pushes the value to
/// `coordinator.queryText` and (if scope was `.folder`) auto-switches scope to
/// `.subfolders` so typing searches the subtree per the unified-query model.
/// If scope is already `.everywhere`, it stays. The clear button empties both
/// the field and the query.
final class SearchField: NSView {
  private let coordinator: AppCoordinator
  private static let accent = Theme.deriveAccent(base: Theme.defaultAccentBase, theme: .dark)

  private let magnifier = NSImageView()
  private let field = InsetTextField()
  private let clearButton = ClearButton()

  private var debounce: DispatchWorkItem?
  private var focused = false
  /// Guards programmatic field updates (refresh) from re-triggering the change
  /// pipeline / auto-scope switch.
  private var settingProgrammatically = false

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    layer?.backgroundColor = Theme.background.cgColor
    layer?.borderColor = Theme.border.cgColor

    let img = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
    let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    magnifier.image = img?.withSymbolConfiguration(cfg)
    magnifier.contentTintColor = Theme.textTertiary
    magnifier.imageScaling = .scaleProportionallyDown
    magnifier.translatesAutoresizingMaskIntoConstraints = false

    field.translatesAutoresizingMaskIntoConstraints = false
    field.isBordered = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 13, weight: .regular)
    field.textColor = Theme.text
    field.lineBreakMode = .byTruncatingTail
    field.cell?.usesSingleLineMode = true
    field.cell?.isScrollable = true
    field.delegate = self
    field.placeholderAttributedString = NSAttributedString(
      string: "Search — try kind:folder, ext:pdf",
      attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: Theme.textTertiary,
      ],
    )

    clearButton.translatesAutoresizingMaskIntoConstraints = false
    clearButton.isHidden = true
    clearButton.onClick = {
      [weak self] in self?.clear()
    }

    addSubview(magnifier)
    addSubview(field)
    addSubview(clearButton)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 34),
      widthAnchor.constraint(greaterThanOrEqualToConstant: 200),

      magnifier.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      magnifier.centerYAnchor.constraint(equalTo: centerYAnchor),
      magnifier.widthAnchor.constraint(equalToConstant: 15),
      magnifier.heightAnchor.constraint(equalToConstant: 15),

      field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 8),
      field.centerYAnchor.constraint(equalTo: centerYAnchor),
      field.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -6),

      clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
      clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      clearButton.widthAnchor.constraint(equalToConstant: 18),
      clearButton.heightAnchor.constraint(equalToConstant: 18),
    ])
    // Flexible: grows with available toolbar width but can be compressed.
    setContentHuggingPriority(.defaultLow, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) not used")
  }

  /// Sync the field text from the coordinator (e.g. after navigation clears the
  /// query). Programmatic; does not re-fire the change pipeline.
  func refresh() {
    let value = coordinator.queryText
    if field.stringValue != value {
      settingProgrammatically = true
      field.stringValue = value
      settingProgrammatically = false
    }
    clearButton.isHidden = value.isEmpty
  }

  private func clear() {
    debounce?.cancel()
    // TODO: liekly a code smell, this is probably poorly impemented and a hack.
    settingProgrammatically = true
    field.stringValue = ""
    settingProgrammatically = false
    clearButton.isHidden = true
    coordinator.queryText = ""  // fires onResultsChange via didSet
  }

  /// Debounced push of the field's text to the coordinator + auto-scope switch.
  private func scheduleCommit() {
    debounce?.cancel()
    let text = field.stringValue
    let work = DispatchWorkItem {
      [weak self] in self?.commit(text)
    }
    debounce = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }

  private func commit(_ text: String) {
    // Typing into a folder-scoped search should search the subtree; leave an
    // explicit Everywhere scope alone.
    if !text.isEmpty, coordinator.scope == .folder {
      coordinator.scope = .subfolders  // fires onResultsChange
    }
    coordinator.queryText = text  // fires onResultsChange
  }

  // MARK: Focus ring

  private func setFocused(_ value: Bool) {
    guard value != focused else {
      return
    }
    focused = value
    if value {
      layer?.borderColor = SearchField.accent.accentLine.cgColor
      layer?.backgroundColor = Theme.panel.cgColor
      layer?.shadowColor = SearchField.accent.accentSoft.cgColor
      layer?.shadowOpacity = 1
      layer?.shadowRadius = 3
      layer?.shadowOffset = .zero
      magnifier.contentTintColor = SearchField.accent.accent
    } else {
      layer?.borderColor = Theme.border.cgColor
      layer?.backgroundColor = Theme.background.cgColor
      layer?.shadowOpacity = 0
      magnifier.contentTintColor = Theme.textTertiary
    }
  }
}

// MARK: - NSTextFieldDelegate

extension SearchField: NSTextFieldDelegate {
  func controlTextDidChange(_: Notification) {
    guard !settingProgrammatically else {
      return
    }
    clearButton.isHidden = field.stringValue.isEmpty
    scheduleCommit()
  }

  func controlTextDidBeginEditing(_: Notification) {
    setFocused(true)
  }

  func controlTextDidEndEditing(_: Notification) {
    setFocused(false)
  }
}

// MARK: - Field with an I-beam cursor

private final class InsetTextField: NSTextField {
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .iBeam)
  }
}

// MARK: - Clear (✕) button

/// An 18×18 borderless circle with an ✕ glyph; tertiary, brightening on hover.
private final class ClearButton: NSView {
  var onClick: (() -> Void)?
  private let imageView = NSImageView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.cornerRadius = 9
    let img = NSImage(
      systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear search",
    )
    let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    imageView.image = img?.withSymbolConfiguration(cfg)
    imageView.contentTintColor = Theme.textTertiary
    imageView.imageScaling = .scaleProportionallyDown
    imageView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)
    NSLayoutConstraint.activate([
      imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
      imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      imageView.widthAnchor.constraint(equalToConstant: 14),
      imageView.heightAnchor.constraint(equalToConstant: 14),
    ])
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError()
  }

  override func mouseDown(with _: NSEvent) {
    let up = window?.nextEvent(matching: [.leftMouseUp])
    if let up,
      bounds.contains(convert(up.locationInWindow, from: nil))
    {
      onClick?()
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
    imageView.contentTintColor = Theme.text
  }

  override func mouseExited(with _: NSEvent) {
    imageView.contentTintColor = Theme.textTertiary
  }
}
