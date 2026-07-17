import AppKit

/// Editable path control for the toolbar. Two modes:
///
/// - **Display:** the current path as styled, clickable tokens. Under home it
///   shows a leading accent-colored `~`; otherwise a leading `/` root token.
///   Segments are separated by a dim `⁄`; parent segments are tertiary, the
///   current (last) segment is `Theme.text` semibold. Clicking a segment
///   navigates to that ancestor. Clicking empty space (or the control chrome)
///   enters edit mode.
/// - **Edit:** the whole control swaps to a mono `NSTextField` prefilled with the
///   absolute current path, fully selected and focused. Enter navigates; Esc or
///   blur reverts to display. This is the paste-a-path-and-go feature.
///
/// Interaction chosen: **segment-click navigates + click-empty-space edits.**
/// Segments are real clickable buttons stacked left-to-right; the remaining
/// trailing area of the container is a transparent hit target that enters edit
/// mode, and clicking the container background (mouseDown not on a segment) also
/// edits. This satisfies both "jump to an ancestor" and "paste a path and go".
final class Breadcrumb: NSView {
  private let coordinator: AppCoordinator
  private static let accent = Theme.darkAccent

  private let stack = NSStackView()
  private let editField = EditField()
  private var editing = false
  /// Active only in edit mode — display mode hugs the crumb content.
  private var editWidthConstraint: NSLayoutConstraint?

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.borderWidth = 1
    layer?.borderColor = NSColor.clear.cgColor

    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 2
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
    addSubview(stack)

    editField.translatesAutoresizingMaskIntoConstraints = false
    editField.isHidden = true
    editField.delegate = self
    editField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    editField.textColor = Theme.text
    editField.isBordered = false
    editField.drawsBackground = false
    editField.focusRingType = .none
    editField.lineBreakMode = .byTruncatingHead
    editField.cell?.usesSingleLineMode = true
    editField.cell?.isScrollable = true
    addSubview(editField)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      // Equality: the control is exactly as wide as its crumbs, so the
      // click-to-edit hit target never extends into the empty toolbar gap.
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),

      editField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      editField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      editField.centerYAnchor.constraint(equalTo: centerYAnchor),

      heightAnchor.constraint(equalToConstant: 32),
    ])
    // A pasted path needs room to read/type: while editing, the control
    // stretches toward the toolbar's cap instead of hugging the crumbs.
    editWidthConstraint = widthAnchor.constraint(greaterThanOrEqualToConstant: 360)
    editWidthConstraint?.priority = NSLayoutConstraint.Priority(750)
    setContentHuggingPriority(.required, for: .horizontal)
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    refresh()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) not used")
  }

  // MARK: Display mode

  /// Rebuild the token row from `coordinator.currentPath`.
  func refresh() {
    guard !editing else {
      return
    }
    for sub in stack.arrangedSubviews {
      stack.removeArrangedSubview(sub)
      sub.removeFromSuperview()
    }

    let path = coordinator.currentPath
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    if path == home {
      stack.addArrangedSubview(makeSegment(text: "~", path: home, style: .home))
      return
    }

    // Render under-home paths with a `~` prefix; otherwise from root `/`.
    var segments: [(name: String, fullPath: String)] = []
    if path.hasPrefix(home + "/") {
      stack.addArrangedSubview(makeSegment(text: "~", path: home, style: .home))
      let rest = String(path.dropFirst(home.count + 1))
      var acc = home
      for name in rest.split(separator: "/").map(String.init) {
        acc = (acc as NSString).appendingPathComponent(name)
        segments.append((name, acc))
      }
    } else {
      stack.addArrangedSubview(makeRootToken())
      var acc = ""
      for name in path.split(separator: "/").map(String.init) {
        acc = acc + "/" + name
        segments.append((name, acc))
      }
    }

    for (i, seg) in segments.enumerated() {
      // Separator before every segment that follows the home/root token,
      // and between segments.
      if i > 0 || !stack.arrangedSubviews.isEmpty {
        stack.addArrangedSubview(makeSeparator())
      }
      let isCurrent = i == segments.count - 1
      stack.addArrangedSubview(
        makeSegment(text: seg.name, path: seg.fullPath, style: isCurrent ? .current : .parent))
    }
  }

  private enum SegStyle {
    case home, parent, current
  }

  private func makeSegment(text: String, path: String, style: SegStyle) -> SegmentView {
    let font: NSFont
    let color: NSColor
    switch style {
    case .home:
      font = .monospacedSystemFont(ofSize: 12.5, weight: .semibold)
      color = Breadcrumb.accent.accent
    case .parent:
      font = .systemFont(ofSize: 12.5, weight: .regular)
      color = coordinator.userState.folderColor(forPath: path) ?? Theme.textTertiary
    case .current:
      font = .systemFont(ofSize: 12.5, weight: .semibold)
      color = coordinator.userState.folderColor(forPath: path) ?? Theme.text
    }
    return SegmentView(text: text, font: font, color: color, navPath: path) {
      [weak self] target in
      self?.coordinator.navigate(to: target)
    }
  }

  private func makeSeparator() -> NSTextField {
    let l = NSTextField(labelWithString: "\u{2044}")  // ⁄ fraction slash
    l.font = .systemFont(ofSize: 13, weight: .regular)
    l.textColor = Theme.textTertiary
    l.alphaValue = 0.7
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
  }

  private func makeRootToken() -> SegmentView {
    SegmentView(
      text: "/", font: .systemFont(ofSize: 12.5, weight: .regular),
      color: Theme.textTertiary, navPath: "/"
    ) {
      [weak self] target in
      self?.coordinator.navigate(to: target)
    }
  }

  // MARK: Edit mode

  private func enterEdit() {
    guard !editing else {
      return
    }
    editing = true
    stack.isHidden = true
    editField.isHidden = false
    editWidthConstraint?.isActive = true
    editField.stringValue = coordinator.currentPath

    // Accent focus ring: border accentLine + soft glow.
    layer?.backgroundColor = Theme.background.cgColor
    layer?.borderColor = Breadcrumb.accent.accentLine.cgColor
    layer?.shadowColor = Breadcrumb.accent.accentSoft.cgColor
    layer?.shadowOpacity = 1
    layer?.shadowRadius = 3
    layer?.shadowOffset = .zero

    if let win = window {
      win.makeFirstResponder(editField)
      editField.currentEditor()?.selectAll(nil)
    }
    needsDisplay = true
  }

  private func exitEdit() {
    guard editing else {
      return
    }
    editing = false
    editField.isHidden = true
    stack.isHidden = false
    editWidthConstraint?.isActive = false
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.borderColor = NSColor.clear.cgColor
    layer?.shadowOpacity = 0
    refresh()
    needsDisplay = true
  }

  private func commitEdit() {
    let value = editField.stringValue
    let ok = coordinator.navigate(to: value)
    guard ok else {
      // Bad path: beep and stay in edit mode with text selected.
      NSSound.beep()
      editField.currentEditor()?.selectAll(nil)
      return
    }
    // Success: exit edit mode. Set editing = false before refresh() so the
    // rebuilt crumbs reflect the new path (refresh() guards on editing).
    editing = false
    editField.isHidden = true
    stack.isHidden = false
    editWidthConstraint?.isActive = false
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.borderColor = NSColor.clear.cgColor
    layer?.shadowOpacity = 0
    window?.makeFirstResponder(window)  // drop focus off the now-hidden field
    refresh()
    needsDisplay = true  // parity with exitEdit()'s visual teardown
  }

  // MARK: Hit-testing for click-to-edit

  override func mouseDown(with event: NSEvent) {
    if editing {
      super.mouseDown(with: event)
      return
    }
    // Clicks landing on a SegmentView are routed to that subview by AppKit's
    // hitTest, so reaching here means the click hit empty space / chrome.
    enterEdit()
  }

  // Hover background on the display control.
  private var trackingArea: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let t = trackingArea {
      removeTrackingArea(t)
    }
    let t = NSTrackingArea(
      rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(t)
    trackingArea = t
  }

  override func mouseEntered(with event: NSEvent) {
    guard isTopmostUnderMouse else { return }
    guard !editing else {
      return
    }
    layer?.backgroundColor = Theme.hover.cgColor
  }

  override func mouseExited(with event: NSEvent) {
    guard !editing else {
      return
    }
    layer?.backgroundColor = NSColor.clear.cgColor
  }
}

// MARK: - NSTextFieldDelegate (commit / cancel)

extension Breadcrumb: NSTextFieldDelegate {
  func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector)
    -> Bool
  {
    if commandSelector == #selector(NSResponder.insertNewline(_:)) {
      commitEdit()
      return true
    }
    if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
      exitEdit()
      return true
    }
    return false
  }

  func controlTextDidEndEditing(_ obj: Notification) {
    // Blur reverts to display (commit only happens on Enter).
    if editing {
      exitEdit()
    }
  }
}

// MARK: - Segment view

/// A clickable styled label that navigates to a fixed ancestor path on click.
/// Layer-backed so it can show a light rounded hover background; a custom view
/// (not NSButton) so there's no default bezel to draw an unwanted background.
private final class SegmentView: NSView {
  private let navPath: String
  private let onClick: (String) -> Void
  private let label = NSTextField(labelWithString: "")

  init(
    text: String, font: NSFont, color: NSColor, navPath: String, onClick: @escaping (String) -> Void
  ) {
    self.navPath = navPath
    self.onClick = onClick
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 4

    label.attributedStringValue = NSAttributedString(
      string: text,
      attributes: [
        .font: font, .foregroundColor: color,
      ])
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
      label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
    ])
    setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
  }

  required init?(coder: NSCoder) {
    fatalError()
  }

  override func mouseDown(with event: NSEvent) {
    let up = window?.nextEvent(matching: [.leftMouseUp])
    if let up, bounds.contains(convert(up.locationInWindow, from: nil)) {
      onClick(navPath)
    }
  }

  // Light hover affordance per crumb.
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
    guard isTopmostUnderMouse else { return }
    // One step lighter than the container pill's Theme.hover — the same
    // color would make the per-segment highlight invisible while the whole
    // breadcrumb is hovered.
    layer?.backgroundColor = Theme.hoverRaised.cgColor
  }

  override func mouseExited(with event: NSEvent) {
    layer?.backgroundColor = NSColor.clear.cgColor
  }
}

// MARK: - Edit field

/// NSTextField subclass that keeps a text (I-beam) cursor over the edit area.
private final class EditField: NSTextField {
  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .iBeam)
  }
}
