import AppKit

/// The 28pt status strip at the bottom of the window (spec §6.3 / §7, v2
/// prototype). Three regions on a `Theme.panel` bar:
///   left   — a live green dot + "<formatted count> files indexed" (click-to-copy)
///   center — the current selection summary (mono, secondary)
///   right  — "updated <relative>" from the index file's mtime
final class StatusBarView: NSView {
  private let coordinator: AppCoordinator

  private let liveDot = LiveDotView()
  private let countLabel = ClickToCopyLabel()
  private let countSuffix = NSTextField(labelWithString: "files indexed")
  private let selectionLabel = NSTextField(labelWithString: "")
  private let freshnessLabel = NSTextField(labelWithString: "")

  private static let accent = Theme.deriveAccent(base: Theme.defaultAccentBase, theme: .dark)

  /// Count formatter: SPACE thousands separators (e.g. 1 240 118).
  private static let countFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.usesGroupingSeparator = true
    f.groupingSeparator = "\u{00A0}"  // non-breaking space, renders as a thin gap
    f.groupingSize = 3
    return f
  }()

  init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = Theme.panel.cgColor
    build()
    refresh()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

  override var isFlipped: Bool { false }

  private func build() {
    // Left cluster: dot + count + " files indexed".
    liveDot.translatesAutoresizingMaskIntoConstraints = false

    countLabel.translatesAutoresizingMaskIntoConstraints = false
    countLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .semibold)
    countLabel.textColor = Theme.textSecondary
    countLabel.onCopy = { [weak self] in self?.copyCount() }

    countSuffix.translatesAutoresizingMaskIntoConstraints = false
    countSuffix.font = .systemFont(ofSize: 11.5, weight: .regular)
    countSuffix.textColor = Theme.textTertiary

    selectionLabel.translatesAutoresizingMaskIntoConstraints = false
    selectionLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
    selectionLabel.textColor = Theme.textSecondary
    selectionLabel.alignment = .center
    selectionLabel.lineBreakMode = .byTruncatingMiddle
    selectionLabel.cell?.truncatesLastVisibleLine = true
    selectionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    freshnessLabel.translatesAutoresizingMaskIntoConstraints = false
    freshnessLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
    freshnessLabel.textColor = Theme.textTertiary
    freshnessLabel.alignment = .right

    for v in [liveDot, countLabel, countSuffix, selectionLabel, freshnessLabel] as [NSView] {
      addSubview(v)
    }

    NSLayoutConstraint.activate([
      // Left cluster.
      liveDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      liveDot.centerYAnchor.constraint(equalTo: centerYAnchor),
      liveDot.widthAnchor.constraint(equalToConstant: 7),
      liveDot.heightAnchor.constraint(equalToConstant: 7),

      countLabel.leadingAnchor.constraint(equalTo: liveDot.trailingAnchor, constant: 6),
      countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      countSuffix.leadingAnchor.constraint(equalTo: countLabel.trailingAnchor, constant: 4),
      countSuffix.centerYAnchor.constraint(equalTo: centerYAnchor),

      // Right cluster.
      freshnessLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      freshnessLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      // Center summary fills the gap between the two clusters.
      selectionLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      selectionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      selectionLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: countSuffix.trailingAnchor, constant: 12),
      selectionLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: freshnessLabel.leadingAnchor, constant: -12),
    ])

    // Don't let the side clusters get compressed by the center label.
    countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    countSuffix.setContentCompressionResistancePriority(.required, for: .horizontal)
    freshnessLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
  }

  // MARK: Public API

  /// Update the center selection summary (nil clears it).
  func setSelection(_ summary: String?) {
    selectionLabel.stringValue = summary ?? ""
  }

  /// Recompute the indexed count (left) and freshness (right).
  func refresh() {
    let count = coordinator.core?.totalCount ?? 0
    countLabel.stringValue = formattedCount(count)
    freshnessLabel.stringValue = Self.freshnessText() ?? ""
  }

  // MARK: Count

  private func formattedCount(_ n: Int) -> String {
    Self.countFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
  }

  /// Copy the formatted count to the pasteboard and flash the label toward
  /// the accent for ~0.4s, then back to its resting color.
  private func copyCount() {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(countLabel.stringValue, forType: .string)
    flashCount()
  }

  private func flashCount() {
    // Animate the text color toward the accent, then back. NSTextField's
    // textColor isn't directly animatable, so step it on a short timer.
    let accent = Self.accent.accent
    let rest = Theme.textSecondary
    countLabel.textColor = accent
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      guard let self else { return }
      // Brief cross-fade back via the layer.
      if let layer = self.countLabel.layer {
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 0.6
        anim.toValue = 1.0
        anim.duration = 0.2
        layer.add(anim, forKey: "flashBack")
      }
      self.countLabel.textColor = rest
    }
  }

  // MARK: Freshness

  /// The index file's modification date as a relative bucket (mirrors the file
  /// list's relativeText). Nil if the index is missing / unreadable.
  private static func freshnessText() -> String? {
    let fm = FileManager.default
    guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      return nil
    }
    let indexURL = support.appendingPathComponent("zest/index.zst")
    guard let attrs = try? fm.attributesOfItem(atPath: indexURL.path),
      let mtime = attrs[.modificationDate] as? Date
    else { return nil }
    return "updated \(relative(from: mtime)) ago"
  }

  /// Relative bucket from a date: <1d "today" → bare, else "Nd"/"Nmo"/"Ny".
  /// (Caller wraps as "updated X ago".)
  private static func relative(from date: Date) -> String {
    let secs = max(0, Int(Date().timeIntervalSince(date)))
    let mins = secs / 60
    if mins < 1 { return "just now" }
    if mins < 60 { return "\(mins)m" }
    let hours = mins / 60
    if hours < 24 { return "\(hours)h" }
    let days = hours / 24
    if days < 30 { return "\(days)d" }
    if days < 365 { return "\(days / 30)mo" }
    return "\(days / 365)y"
  }
}

// MARK: - Live dot

/// A small pulsing green dot signalling the index is live (spec §6.3). Drawn as a
/// filled circle with a soft glow ring; subtle, not animated in snapshots.
private final class LiveDotView: NSView {
  override var wantsUpdateLayer: Bool { false }
  override func draw(_ dirtyRect: NSRect) {
    let color = Theme.catCode
    // Soft glow halo.
    let glow = NSBezierPath(ovalIn: bounds.insetBy(dx: -1.5, dy: -1.5))
    color.withAlphaComponent(0.22).setFill()
    glow.fill()
    // Solid dot.
    let dot = NSBezierPath(ovalIn: bounds)
    color.setFill()
    dot.fill()
  }
}

// MARK: - Click-to-copy label

/// A label that fires `onCopy` on click and shows a copy cursor on hover.
private final class ClickToCopyLabel: NSTextField {
  var onCopy: (() -> Void)?
  private var trackingArea: NSTrackingArea?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    isEditable = false
    isBordered = false
    isSelectable = false
    drawsBackground = false
    wantsLayer = true
    toolTip = "Click to copy"
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

  override func mouseDown(with event: NSEvent) {
    onCopy?()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let ta = NSTrackingArea(
      rect: bounds, options: [.activeInActiveApp, .mouseEnteredAndExited], owner: self,
      userInfo: nil)
    addTrackingArea(ta)
    trackingArea = ta
  }

  override func mouseEntered(with event: NSEvent) { NSCursor.pointingHand.set() }
  override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
}
