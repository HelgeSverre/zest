import AppKit

extension NSView {
  /// True when the view under the mouse is this view or one of its
  /// descendants. NSTrackingArea fires by geometry alone, regardless of
  /// z-order, so hover effects must check this or they light up through
  /// the saved-filters card / dialog scrim overlays.
  var isTopmostUnderMouse: Bool {
    guard let window else { return false }
    let point = window.mouseLocationOutsideOfEventStream
    guard let hit = window.contentView?.superview?.hitTest(point) else { return false }
    return hit === self || hit.isDescendant(of: self)
  }
}
