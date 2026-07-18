import AppKit

/// Root-mounted custom preview for Markdown, Sema, and JSON files. The view is
/// intentionally never made first responder: the browser table keeps keyboard
/// focus so an open preview follows Up/Down selection changes.
final class FilePreviewOverlay: NSView {
  var onClose: (() -> Void)?

  private let loader: PreviewContentLoader
  private let panel = NSView()
  private let filenameLabel = NSTextField(labelWithString: "")
  private let scrollView = NSScrollView()
  private let textView = NSTextView()

  init(loader: PreviewContentLoader = PreviewContentLoader()) {
    self.loader = loader
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    wantsLayer = true
    layer?.backgroundColor = Theme.scrim.cgColor
    isHidden = true
    buildPanel()
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) not used")
  }

  var isShown: Bool { !isHidden }

  func show(url: URL, format: PreviewFormat) {
    filenameLabel.stringValue = url.lastPathComponent
    setBody(
      NSAttributedString(
        string: "Loading…",
        attributes: [
          .font: NSFont.systemFont(ofSize: 13),
          .foregroundColor: Theme.textSecondary,
        ]
      )
    )
    isHidden = false

    loader.load(url: url, format: format) { [weak self] result in
      guard let self else { return }
      switch result {
      case .success(let content):
        self.setBody(content.attributedString)
      case .failure(let error):
        self.showError(filename: url.lastPathComponent, message: error.localizedDescription)
      }
    }
  }

  func showError(filename: String, message: String) {
    filenameLabel.stringValue = filename
    let errorBody = NSMutableAttributedString(
      string: "Preview unavailable",
      attributes: [
        .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
        .foregroundColor: Theme.text,
      ]
    )
    errorBody.append(
      NSAttributedString(
        string: "\n\n\(message)",
        attributes: [
          .font: NSFont.systemFont(ofSize: 12.5),
          .foregroundColor: Theme.textSecondary,
        ]
      ))
    setBody(errorBody)
    isHidden = false
  }

  func hide() {
    loader.invalidate()
    isHidden = true
    filenameLabel.stringValue = ""
    textView.textStorage?.setAttributedString(NSAttributedString())
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if !panel.frame.contains(point) {
      onClose?()
    }
  }

  override func rightMouseDown(with _: NSEvent) {}
  override func otherMouseDown(with _: NSEvent) {}
  override func scrollWheel(with _: NSEvent) {}

  override func cancelOperation(_: Any?) {
    onClose?()
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      onClose?()
    } else {
      super.keyDown(with: event)
    }
  }

  private func buildPanel() {
    panel.translatesAutoresizingMaskIntoConstraints = false
    panel.wantsLayer = true
    panel.layer?.backgroundColor = Theme.panel2.cgColor
    panel.layer?.borderWidth = 1
    panel.layer?.borderColor = Theme.border.cgColor
    panel.layer?.cornerRadius = 12
    panel.layer?.masksToBounds = true

    let header = NSView()
    header.translatesAutoresizingMaskIntoConstraints = false

    filenameLabel.translatesAutoresizingMaskIntoConstraints = false
    filenameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    filenameLabel.textColor = Theme.text
    filenameLabel.lineBreakMode = .byTruncatingMiddle
    filenameLabel.maximumNumberOfLines = 1

    let closeButton = DialogIconButton(
      symbol: "xmark",
      accessibility: "Close preview",
      hoverBackground: Theme.hover,
      hoverTint: Theme.text
    )
    closeButton.target = self
    closeButton.action = #selector(closeTapped)

    header.addSubview(filenameLabel)
    header.addSubview(closeButton)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.drawsBackground = true
    scrollView.backgroundColor = Theme.background
    scrollView.borderType = .noBorder

    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = true
    textView.importsGraphics = false
    textView.drawsBackground = true
    textView.backgroundColor = Theme.background
    textView.textContainerInset = NSSize(width: 18, height: 16)
    textView.isHorizontallyResizable = true
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width]
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.textContainer?.widthTracksTextView = false
    scrollView.documentView = textView

    let hairline = Hairline()
    for child in [header, hairline, scrollView] {
      child.translatesAutoresizingMaskIntoConstraints = false
      panel.addSubview(child)
    }
    addSubview(panel)

    // AppKit holds an NSWindow's size at priority 500. Panel preferences must
    // yield below that threshold or their absolute caps become window caps.
    let panelSizingPriority = NSLayoutConstraint.Priority(499)
    let preferredWidth = panel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.78)
    preferredWidth.priority = panelSizingPriority
    let preferredHeight = panel.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.78)
    preferredHeight.priority = panelSizingPriority

    NSLayoutConstraint.activate([
      panel.centerXAnchor.constraint(equalTo: centerXAnchor),
      panel.centerYAnchor.constraint(equalTo: centerYAnchor),
      preferredWidth,
      preferredHeight,
      panel.widthAnchor.constraint(greaterThanOrEqualToConstant: 520),
      panel.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
      panel.widthAnchor.constraint(lessThanOrEqualToConstant: 1_080),
      panel.heightAnchor.constraint(lessThanOrEqualToConstant: 820),

      header.topAnchor.constraint(equalTo: panel.topAnchor),
      header.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
      header.heightAnchor.constraint(equalToConstant: 48),
      filenameLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 18),
      filenameLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
      filenameLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),
      closeButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
      closeButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),

      hairline.topAnchor.constraint(equalTo: header.bottomAnchor),
      hairline.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
      hairline.heightAnchor.constraint(equalToConstant: 1),
      scrollView.topAnchor.constraint(equalTo: hairline.bottomAnchor),
      scrollView.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
    ])
  }

  private func setBody(_ attributedString: NSAttributedString) {
    textView.textStorage?.setAttributedString(attributedString)
    textView.scrollToBeginningOfDocument(nil)
  }

  @objc private func closeTapped() {
    onClose?()
  }
}
