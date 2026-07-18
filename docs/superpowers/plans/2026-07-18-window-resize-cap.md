# Window Resize Cap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow the Zest window to expand across the available display while preserving the file-preview panel's proportional sizing and absolute bounds.

**Architecture:** Keep the overlay and panel constraint graph active in both visibility states. Express the 78% panel width and height as priority-499 preferences—below AppKit's priority-500 window-size policy—while retaining the 520×360 minimum and 1,080×820 maximum as required constraints.

**Tech Stack:** Swift 5.9, AppKit Auto Layout, XCTest.

## Global Constraints

- Keep the macOS deployment target at 14.
- Do not change toolbar, breadcrumb, search-field, or window minimum-size policies.
- The preview panel remains centered and uses 78% of the host size until an absolute bound wins.
- Do not modify or stage `reddit-scrutiny.json`.

---

### Task 1: Remove the derived host-window maximum

**Files:**
- Create: `Sources/ZestTests/FilePreviewOverlayTests.swift`
- Modify: `Sources/Zest/Shell/FilePreviewOverlay.swift:175-182`

**Interfaces:**
- Consumes: `FilePreviewOverlay.init()` and its existing root-pinned layout.
- Produces: an overlay whose proportional panel constraints have priority 499 and whose absolute panel bounds remain required.

- [x] **Step 1: Write the failing oversized-window regression test**

Create an AppKit window with a root view controller, pin a `FilePreviewOverlay` to all four root edges, request a 1,700×1,100 pt content size, force layout, and assert that the content view accepts both requested dimensions within 0.5 pt. The current required proportional and maximum constraints must cause the width assertion to fail at approximately 1,385 pt.

```swift
import AppKit
import XCTest

@testable import Zest

final class FilePreviewOverlayTests: XCTestCase {
  func testOverlayDoesNotCapHostingWindowSize() {
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
  }
}
```

- [x] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter FilePreviewOverlayTests`

Expected: FAIL because the window content width or height is clamped by the overlay's required constraint graph.

- [x] **Step 3: Make proportional sizing a preference**

Create the width and height proportional constraints before activation, assign each `NSLayoutConstraint.Priority(499)`, and activate them alongside the existing required centering and bound constraints. Do not alter the 0.78 multiplier or the 520×360 and 1,080×820 constants.

```swift
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
  // Existing panel-content constraints remain unchanged.
])
```

- [x] **Step 4: Run focused and full verification**

Run: `swift test --filter FilePreviewOverlayTests && just test`

Expected: the regression test passes and the complete Zig/Swift suite reports zero failures, leaving `libzest-core.a` rebuilt with `ReleaseFast`.

- [x] **Step 5: Verify the live resize behavior**

Launch `swift run Zest`, use Accessibility scripting to position the window at the display's leading edge and request a size wider than the former 1,385 pt cap, then read the resulting size back. Expect the accepted width to exceed 1,385 pt with no Auto Layout diagnostics.

- [x] **Step 6: Review and commit**

Run changed-file `swift-format` lint, `git diff --check`, and diff-based self-review. Commit the implementation and test without staging `reddit-scrutiny.json`.
