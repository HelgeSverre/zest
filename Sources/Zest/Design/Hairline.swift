import AppKit

/// 1pt (device-pixel) divider line.
final class Hairline: NSView {
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 1)
  }

  init() {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = Theme.border.cgColor
    setContentHuggingPriority(.required, for: .vertical)
    setContentCompressionResistancePriority(.required, for: .vertical)
  }

  required init?(coder: NSCoder) {
    fatalError()
  }
}
