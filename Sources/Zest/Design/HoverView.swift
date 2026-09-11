import AppKit

/// Shared mouse plumbing for the hand-rolled controls. An extension rather than
/// a base class so NSButton/NSTextField subclasses get the same code path.
extension NSView {
  private static let hoverKey = "dev.zest.hover"

  /// (Re)install the standard hover tracking area. Call from
  /// `updateTrackingAreas()` after `super`; `mouseEntered`/`mouseExited`
  /// then fire for the visible rect while the app is active.
  func refreshHoverTracking() {
    for area in trackingAreas where area.userInfo?[Self.hoverKey] != nil {
      removeTrackingArea(area)
    }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
        owner: self, userInfo: [Self.hoverKey: true]))
  }

  /// Standard button feel: run `body` only if the matching mouse-up lands
  /// inside the view. Call from `mouseDown`.
  func trackClick(_ body: () -> Void) {
    let up = window?.nextEvent(matching: [.leftMouseUp])
    if let up, bounds.contains(convert(up.locationInWindow, from: nil)) { body() }
  }

  /// Fade from transparent to opaque.
  func fadeIn(duration: TimeInterval) {
    alphaValue = 0
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = duration
      animator().alphaValue = 1
    }
  }
}

extension NSStackView {
  /// Remove every arranged subview from the stack and the view hierarchy.
  func removeAllArranged() {
    for view in arrangedSubviews {
      removeArrangedSubview(view)
      view.removeFromSuperview()
    }
  }
}
