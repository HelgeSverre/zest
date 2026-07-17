import AppKit

/// NSClipView is not flipped, so a plain documentView anchors to the
/// *bottom* of the scroll area. Flipping the stack keeps rows pinned to
/// the top.
final class FlippedStackView: NSStackView {
  override var isFlipped: Bool { true }
}

/// In-window saved-filters manager: a scrim covering the whole content view
/// with a centered panel (prototype `.overlay` / `.ovl-panel`). CRUD over the
/// coordinator's `savedFilters`. Mounted once by RootViewController, hidden
/// until `show()`.
final class SavedFiltersDialog: NSView {
  private let coordinator: AppCoordinator
  private var editingIndex: Int?  // nil = none; -1 = new filter
  /// Pre-fill the new-filter form with this query when opening.
  private var prefillQuery: String?

  private let panel = NSView()
  private let scroll = NSScrollView()
  private let stack = FlippedStackView()
  private let newButton = DialogButton(title: "+ New filter", style: .neutral)
  private let doneButton = DialogButton(title: "Done", style: .primary)

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = Theme.scrim.cgColor
    isHidden = true
    buildPanel()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

  // MARK: - Show / hide

  var isShown: Bool { !isHidden }

  func show(prefillQuery: String? = nil) {
    self.prefillQuery = prefillQuery
    editingIndex = prefillQuery != nil ? -1 : nil
    isHidden = false
    reload()
    if editingIndex == nil { window?.makeFirstResponder(self) }
    alphaValue = 0
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.16
      animator().alphaValue = 1
    }
  }

  func hide() {
    editingIndex = nil
    prefillQuery = nil
    // The dialog stays mounted while hidden; a hidden NSButton can still
    // catch its key equivalent, so strip Return from Done and tear down the
    // body (kills any live Save "\r" button and stale field editors).
    doneButton.keyEquivalent = ""
    clearStack()
    window?.makeFirstResponder(nil)
    isHidden = true
  }

  // MARK: - Scrim behavior

  override var acceptsFirstResponder: Bool { true }

  /// Scrim click closes; panel clicks (that no child handled) are swallowed.
  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if !panel.frame.contains(p) { hide() }
  }

  // Nothing reaches the app underneath.
  override func rightMouseDown(with event: NSEvent) {}
  override func otherMouseDown(with event: NSEvent) {}
  override func scrollWheel(with event: NSEvent) {}

  /// Esc: cancel an open edit form first; second Esc closes the dialog.
  /// Reaches us via the responder chain from the field editor, or directly
  /// when the dialog itself is first responder.
  override func cancelOperation(_ sender: Any?) {
    handleEscape()
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      handleEscape()
    } else {
      super.keyDown(with: event)
    }
  }

  private func handleEscape() {
    if editingIndex != nil {
      editingIndex = nil
      prefillQuery = nil
      reload()
      window?.makeFirstResponder(self)
    } else {
      hide()
    }
  }

  // MARK: - Panel construction

  private func buildPanel() {
    panel.translatesAutoresizingMaskIntoConstraints = false
    panel.wantsLayer = true
    panel.layer?.backgroundColor = Theme.panel2.cgColor
    panel.layer?.borderWidth = 1
    panel.layer?.borderColor = Theme.border.cgColor
    panel.layer?.cornerRadius = 12
    panel.layer?.masksToBounds = false
    // ≈ --shadow-dialog: 0 30px 70px -20px rgba(0,0,0,.8)
    panel.shadow = NSShadow()
    panel.layer?.shadowColor = NSColor.black.cgColor
    panel.layer?.shadowOpacity = 0.7
    panel.layer?.shadowRadius = 35
    panel.layer?.shadowOffset = CGSize(width: 0, height: -22)

    // Header
    let header = NSView()
    header.translatesAutoresizingMaskIntoConstraints = false

    let title = NSTextField(labelWithString: "Saved Filters")
    title.font = .systemFont(ofSize: 14, weight: .semibold)
    title.textColor = Theme.text
    title.translatesAutoresizingMaskIntoConstraints = false

    let subtitle = NSTextField(labelWithString: "Create, edit, and organize reusable searches")
    subtitle.font = .systemFont(ofSize: 11.5)
    subtitle.textColor = Theme.textTertiary
    subtitle.translatesAutoresizingMaskIntoConstraints = false

    let closeButton = DialogIconButton(
      symbol: "xmark", accessibility: "Close",
      hoverBackground: Theme.hover, hoverTint: Theme.text)
    closeButton.target = self
    closeButton.action = #selector(closeTapped)

    header.addSubview(title)
    header.addSubview(subtitle)
    header.addSubview(closeButton)
    NSLayoutConstraint.activate([
      title.topAnchor.constraint(equalTo: header.topAnchor, constant: 16),
      title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
      subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
      subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
      subtitle.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -16),
      closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -18),
      closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
    ])

    // Body
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 0
    stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    stack.translatesAutoresizingMaskIntoConstraints = false

    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = false
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.documentView = stack

    // Footer
    let footer = NSView()
    footer.translatesAutoresizingMaskIntoConstraints = false

    newButton.target = self
    newButton.action = #selector(startNewFilter)
    doneButton.target = self
    doneButton.action = #selector(closeTapped)

    footer.addSubview(newButton)
    footer.addSubview(doneButton)
    NSLayoutConstraint.activate([
      footer.heightAnchor.constraint(equalToConstant: 54),
      newButton.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
      newButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
      doneButton.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -16),
      doneButton.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
    ])

    let h1 = Hairline()
    let h2 = Hairline()
    for v in [header, h1, scroll, h2, footer] {
      v.translatesAutoresizingMaskIntoConstraints = false
      panel.addSubview(v)
    }
    addSubview(panel)

    // Panel hugs its content until the 80%-height cap forces the body to
    // scroll (scroll == stack height is the breakable constraint).
    let preferredWidth = panel.widthAnchor.constraint(equalToConstant: 560)
    preferredWidth.priority = NSLayoutConstraint.Priority(999)
    let hugContent = scroll.heightAnchor.constraint(equalTo: stack.heightAnchor)
    hugContent.priority = .defaultHigh

    var c: [NSLayoutConstraint] = [
      panel.centerXAnchor.constraint(equalTo: centerXAnchor),
      panel.centerYAnchor.constraint(equalTo: centerYAnchor),
      preferredWidth,
      panel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),
      panel.heightAnchor.constraint(lessThanOrEqualTo: heightAnchor, multiplier: 0.8),
      hugContent,
      stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
    ]
    for v in [header, h1, scroll, h2, footer] {
      c.append(v.leadingAnchor.constraint(equalTo: panel.leadingAnchor))
      c.append(v.trailingAnchor.constraint(equalTo: panel.trailingAnchor))
    }
    c += [
      header.topAnchor.constraint(equalTo: panel.topAnchor),
      h1.topAnchor.constraint(equalTo: header.bottomAnchor),
      scroll.topAnchor.constraint(equalTo: h1.bottomAnchor),
      h2.topAnchor.constraint(equalTo: scroll.bottomAnchor),
      footer.topAnchor.constraint(equalTo: h2.bottomAnchor),
      footer.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
    ]
    NSLayoutConstraint.activate(c)
  }

  // MARK: - Data

  private func clearStack() {
    for view in stack.arrangedSubviews {
      stack.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }

  /// Adds a row stretched to the body width (stack edgeInsets are 10/side).
  private func addRow(_ row: NSView) {
    stack.addArrangedSubview(row)
    row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
  }

  private func reload() {
    clearStack()

    // While an edit form is open, Return belongs to its Save button.
    doneButton.keyEquivalent = editingIndex == nil ? "\r" : ""

    let filters = coordinator.savedFilters

    if filters.isEmpty && editingIndex == nil {
      let empty = NSTextField(labelWithString: "No saved filters yet — add one below.")
      empty.font = .systemFont(ofSize: 12.5)
      empty.textColor = Theme.textTertiary
      empty.alignment = .center
      empty.translatesAutoresizingMaskIntoConstraints = false
      let container = NSView()
      container.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(empty)
      NSLayoutConstraint.activate([
        empty.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
        empty.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        empty.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      ])
      addRow(container)
    } else {
      for (index, filter) in filters.enumerated() {
        if editingIndex == index {
          let edit = DialogEditForm(name: filter.name, query: filter.query) {
            [weak self] name, query in
            self?.coordinator.updateSavedFilter(at: index, name: name, query: query)
            self?.editingIndex = nil
            self?.reload()
          } onCancel: { [weak self] in
            self?.editingIndex = nil
            self?.reload()
          }
          addRow(edit)
          stack.setCustomSpacing(4, after: edit)
        } else {
          let row = DialogFilterRow(filter: filter) { [weak self] in
            self?.editingIndex = index
            self?.reload()
          } onDelete: { [weak self] in
            guard let self else { return }
            self.coordinator.removeSavedFilter(at: index)
            // Keep the edit form on the same filter when an earlier row
            // is deleted; drop it if the edited row itself was deleted.
            if let editing = self.editingIndex, editing > index {
              self.editingIndex = editing - 1
            } else if self.editingIndex == index {
              self.editingIndex = nil
            }
            self.reload()
          }
          addRow(row)
        }
      }
    }

    if editingIndex == -1 {
      let query = prefillQuery ?? ""
      let edit = DialogEditForm(name: "", query: query) {
        [weak self] name, query in
        self?.coordinator.addSavedFilter(name: name, query: query)
        self?.editingIndex = nil
        self?.prefillQuery = nil
        self?.reload()
      } onCancel: { [weak self] in
        self?.editingIndex = nil
        self?.prefillQuery = nil
        self?.reload()
      }
      addRow(edit)
    }
  }

  @objc private func startNewFilter() {
    editingIndex = -1
    reload()
  }

  @objc private func closeTapped() {
    hide()
  }
}

// MARK: - Buttons

/// Prototype `.btn` family: 30pt, radius 6, layer-styled. A real NSButton so
/// keyEquivalents (Return = Save/Done) keep working like the old sheet.
final class DialogButton: NSButton {
  enum Style { case neutral, primary, ghost }

  private let style: Style
  private static let accent = Theme.darkAccent

  init(title: String, style: Style) {
    self.style = style
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isBordered = false
    setButtonType(.momentaryChange)
    wantsLayer = true
    layer?.cornerRadius = 6
    heightAnchor.constraint(equalToConstant: 30).isActive = true

    let weight: NSFont.Weight = style == .primary ? .semibold : .regular
    let color: NSColor =
      switch style {
      case .neutral: Theme.text
      case .primary: DialogButton.accent.onAccent
      case .ghost: Theme.textSecondary
      }
    attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.systemFont(ofSize: 12.5, weight: weight),
        .foregroundColor: color,
      ])
    applyStyle(hovered: false)
  }

  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize {
    var size = super.intrinsicContentSize
    size.width += 28  // 14pt side padding
    size.height = 30
    return size
  }

  private func applyStyle(hovered: Bool) {
    switch style {
    case .neutral:
      layer?.backgroundColor = (hovered ? Theme.hover : Theme.panelElevated).cgColor
      layer?.borderWidth = 1
      layer?.borderColor = Theme.border.cgColor
    case .primary:
      layer?.backgroundColor = DialogButton.accent.accent.cgColor
      layer?.borderWidth = 0
    case .ghost:
      layer?.backgroundColor = (hovered ? Theme.hover : .clear).cgColor
      layer?.borderWidth = 0
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
    applyStyle(hovered: true)
  }
  override func mouseExited(with event: NSEvent) {
    applyStyle(hovered: false)
  }
}

/// 26×26 transparent icon button (header X, row pencil/trash) with
/// configurable hover background + tint.
final class DialogIconButton: NSButton {
  private let hoverBackground: NSColor
  private let hoverTint: NSColor

  init(symbol: String, accessibility: String?, hoverBackground: NSColor, hoverTint: NSColor) {
    self.hoverBackground = hoverBackground
    self.hoverTint = hoverTint
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    isBordered = false
    setButtonType(.momentaryChange)
    wantsLayer = true
    layer?.cornerRadius = 6
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibility)?
      .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
    imagePosition = .imageOnly
    contentTintColor = Theme.textTertiary
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 26),
      heightAnchor.constraint(equalToConstant: 26),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

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
    layer?.backgroundColor = hoverBackground.cgColor
    contentTintColor = hoverTint
  }
  override func mouseExited(with event: NSEvent) {
    layer?.backgroundColor = NSColor.clear.cgColor
    contentTintColor = Theme.textTertiary
  }
}

// MARK: - Display row

/// Prototype `.sf-row`: grip · name/query · pencil · trash. The whole row is
/// the edit hit-target; the icon buttons consume their own clicks first.
private final class DialogFilterRow: NSView {
  private let onEdit: () -> Void
  private let onDelete: () -> Void

  init(
    filter: UserState.SavedFilter,
    onEdit: @escaping () -> Void, onDelete: @escaping () -> Void
  ) {
    self.onEdit = onEdit
    self.onDelete = onDelete
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 6

    let grip = NSTextField(labelWithString: "⠿")
    grip.font = .systemFont(ofSize: 14)
    grip.textColor = Theme.textTertiary
    grip.translatesAutoresizingMaskIntoConstraints = false

    let nameLabel = NSTextField(labelWithString: filter.name)
    nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
    nameLabel.textColor = Theme.text
    nameLabel.lineBreakMode = .byTruncatingTail
    nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    nameLabel.toolTip = filter.name
    nameLabel.translatesAutoresizingMaskIntoConstraints = false

    let queryLabel = NSTextField(labelWithString: filter.query)
    queryLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    queryLabel.textColor = Theme.textTertiary
    queryLabel.lineBreakMode = .byTruncatingTail
    queryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    queryLabel.translatesAutoresizingMaskIntoConstraints = false

    // The text block absorbs all slack so the pencil/trash buttons stay
    // pinned at the trailing edge regardless of name/query length.
    let vStack = NSStackView(views: [nameLabel, queryLabel])
    vStack.orientation = .vertical
    vStack.alignment = .leading
    vStack.spacing = 2
    vStack.setContentHuggingPriority(.init(1), for: .horizontal)
    nameLabel.setContentHuggingPriority(.init(1), for: .horizontal)
    queryLabel.setContentHuggingPriority(.init(1), for: .horizontal)
    vStack.translatesAutoresizingMaskIntoConstraints = false

    let editBtn = DialogIconButton(
      symbol: "pencil", accessibility: "Edit",
      hoverBackground: Theme.panelElevated, hoverTint: Theme.text)
    editBtn.target = self
    editBtn.action = #selector(editTapped)

    let delBtn = DialogIconButton(
      symbol: "trash", accessibility: "Delete",
      hoverBackground: Theme.panelElevated, hoverTint: Theme.catVideo)
    delBtn.target = self
    delBtn.action = #selector(deleteTapped)

    let hStack = NSStackView(views: [grip, vStack, editBtn, delBtn])
    hStack.orientation = .horizontal
    hStack.alignment = .centerY
    hStack.spacing = 10
    hStack.setCustomSpacing(4, after: editBtn)
    hStack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(hStack)
    NSLayoutConstraint.activate([
      hStack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
      hStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
      hStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      hStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  @objc private func editTapped() { onEdit() }
  @objc private func deleteTapped() { onDelete() }

  override func mouseDown(with event: NSEvent) {
    let up = window?.nextEvent(matching: [.leftMouseUp])
    if let up, bounds.contains(convert(up.locationInWindow, from: nil)) {
      onEdit()
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
    layer?.backgroundColor = Theme.hover.cgColor
  }
  override func mouseExited(with event: NSEvent) {
    layer?.backgroundColor = NSColor.clear.cgColor
  }
}

// MARK: - Edit form

/// NSTextField that reports focus acquisition/loss, so the edit form can
/// show the prototype's accent border the moment a field is focused (the
/// `controlTextDidBeginEditing` delegate hook only fires on the first
/// keystroke, not on focus).
private final class FocusReportingTextField: NSTextField {
  var onFocusChange: ((Bool) -> Void)?

  override func becomeFirstResponder() -> Bool {
    let ok = super.becomeFirstResponder()
    if ok { onFocusChange?(true) }
    return ok
  }

  override func textDidEndEditing(_ notification: Notification) {
    super.textDidEndEditing(notification)
    onFocusChange?(false)
  }
}

/// Prototype `.sf-edit`: inline form on the window-background surface with
/// bordered fields (accent border while focused) + ghost Cancel / primary Save.
private final class DialogEditForm: NSView {
  private static let accent = Theme.darkAccent

  private let onSave: (String, String) -> Void
  private let onCancel: () -> Void

  private let nameField = FocusReportingTextField()
  private let queryField = FocusReportingTextField()

  init(
    name: String, query: String,
    onSave: @escaping (String, String) -> Void,
    onCancel: @escaping () -> Void
  ) {
    self.onSave = onSave
    self.onCancel = onCancel
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.cornerRadius = 8
    layer?.borderWidth = 1
    layer?.borderColor = Theme.border.cgColor
    layer?.backgroundColor = Theme.background.cgColor

    nameField.stringValue = name
    nameField.placeholderString = "Filter name"
    nameField.font = .systemFont(ofSize: 12.5)
    let nameBox = fieldBox(for: nameField)

    queryField.stringValue = query
    queryField.placeholderString = "cat:code date:week"
    queryField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    let queryBox = fieldBox(for: queryField)

    let cancel = DialogButton(title: "Cancel", style: .ghost)
    cancel.target = self
    cancel.action = #selector(cancelTapped)

    let save = DialogButton(title: "Save", style: .primary)
    save.target = self
    save.action = #selector(saveTapped)
    save.keyEquivalent = "\r"

    let btnStack = NSStackView(views: [cancel, save])
    btnStack.orientation = .horizontal
    btnStack.spacing = 8
    btnStack.translatesAutoresizingMaskIntoConstraints = false

    let vStack = NSStackView(views: [
      fieldLabel("NAME"), nameBox, fieldLabel("QUERY"), queryBox, btnStack,
    ])
    vStack.orientation = .vertical
    vStack.alignment = .leading
    vStack.spacing = 4
    vStack.setCustomSpacing(8, after: nameBox)
    vStack.translatesAutoresizingMaskIntoConstraints = false

    addSubview(vStack)
    NSLayoutConstraint.activate([
      vStack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
      vStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      vStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
      vStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
      nameBox.widthAnchor.constraint(equalTo: vStack.widthAnchor),
      queryBox.widthAnchor.constraint(equalTo: vStack.widthAnchor),
      btnStack.trailingAnchor.constraint(equalTo: vStack.trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError() }

  private var didFocus = false
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil, !didFocus else { return }
    didFocus = true
    window?.makeFirstResponder(nameField)
  }

  @objc private func saveTapped() {
    let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let query = queryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else {
      NSSound.beep()
      return
    }
    onSave(name, query)
  }

  @objc private func cancelTapped() {
    onCancel()
  }

  private func fieldLabel(_ text: String) -> NSTextField {
    let l = NSTextField(labelWithString: "")
    l.attributedStringValue = NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.systemFont(ofSize: 10.5),
        .foregroundColor: Theme.textTertiary,
        .kern: 0.63,
      ])
    return l
  }

  /// Wraps a borderless text field in the prototype's bordered input box;
  /// the border flips to the accent line color while the field is focused.
  private func fieldBox(for field: FocusReportingTextField) -> NSView {
    field.translatesAutoresizingMaskIntoConstraints = false
    field.isBordered = false
    field.drawsBackground = false
    field.textColor = Theme.text
    field.focusRingType = .none

    let box = NSView()
    box.translatesAutoresizingMaskIntoConstraints = false
    box.wantsLayer = true
    box.layer?.backgroundColor = Theme.panel.cgColor
    box.layer?.borderWidth = 1
    box.layer?.borderColor = Theme.border.cgColor
    box.layer?.cornerRadius = 6
    box.addSubview(field)
    NSLayoutConstraint.activate([
      box.heightAnchor.constraint(equalToConstant: 30),
      field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 9),
      field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -9),
      field.centerYAnchor.constraint(equalTo: box.centerYAnchor),
    ])
    field.onFocusChange = { [weak box] focused in
      box?.layer?.borderColor =
        (focused ? DialogEditForm.accent.accentLine : Theme.border).cgColor
    }
    return box
  }
}
