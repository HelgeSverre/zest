import AppKit
import XCTest

@testable import Zest

final class FilePreviewOverlayTests: XCTestCase {
  func testOverlayDoesNotCapHostingWindowSize() throws {
    let root = NSViewController()
    root.view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

    let overlay = FilePreviewOverlay()
    root.view.addSubview(overlay)
    NSLayoutConstraint.activate([
      overlay.topAnchor.constraint(equalTo: root.view.topAnchor),
      overlay.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
      overlay.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
      overlay.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
    ])

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentViewController = root

    let requested = NSSize(width: 1_700, height: 1_100)
    window.setContentSize(requested)
    root.view.layoutSubtreeIfNeeded()

    XCTAssertEqual(root.view.bounds.width, requested.width, accuracy: 0.5)
    XCTAssertEqual(root.view.bounds.height, requested.height, accuracy: 0.5)
    let panel = try XCTUnwrap(overlay.subviews.first)
    XCTAssertEqual(panel.bounds.width, 1_080, accuracy: 0.5)
    XCTAssertEqual(panel.bounds.height, 820, accuracy: 0.5)
  }
}
