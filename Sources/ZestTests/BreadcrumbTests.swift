import XCTest

@testable import Zest

/// Table-driven tests for the breadcrumb's middle-collapse fit algorithm.
/// `widths[0]` is the root token (~ or /), `widths.last` the current folder;
/// the returned range is the middle segments to hide behind the … token
/// (empty = everything fits).
final class BreadcrumbCollapseTests: XCTestCase {
  private let sep: CGFloat = 10
  private let ellipsis: CGFloat = 20

  func testEverythingFits() {
    let r = Breadcrumb.segmentsToCollapse(
      widths: [20, 60, 60, 60], ellipsisWidth: ellipsis, separatorWidth: sep, available: 300)
    XCTAssertTrue(r.isEmpty)
  }

  func testOneAncestorHidden() {
    // Total = 20+60+60+60+60 + 4*10 = 300 > 240.
    // Base (root+…+current) = 20+20+60+2*10 = 120; adding deepest ancestors:
    // +70 (idx 3) = 190, +70 (idx 2) = 260 > 240 → keep 3..4, hide 1..<3? No:
    // firstKept=3 after idx3 fits, idx2 breaks → hidden = 1..<3.
    let r = Breadcrumb.segmentsToCollapse(
      widths: [20, 60, 60, 60, 60], ellipsisWidth: ellipsis, separatorWidth: sep, available: 240)
    XCTAssertEqual(1..<3, r)
  }

  func testDeepPathTinyWidthKeepsOnlyRootAndCurrent() {
    let r = Breadcrumb.segmentsToCollapse(
      widths: [20, 80, 80, 80, 80, 80, 60], ellipsisWidth: ellipsis, separatorWidth: sep,
      available: 130)
    XCTAssertEqual(1..<6, r, "all middle segments hidden")
  }

  func testRootPlusCurrentOnlyNeverCollapses() {
    // Nothing between root and current to hide, however narrow.
    let r = Breadcrumb.segmentsToCollapse(
      widths: [20, 300], ellipsisWidth: ellipsis, separatorWidth: sep, available: 100)
    XCTAssertTrue(r.isEmpty, "render layer clamps the current label instead")
  }

  func testCollapseIsNeverEmptyWhenOverflowingWithMiddles() {
    // Regression guard: if the trail overflows and middles exist, at least
    // one must be hidden (otherwise we'd render an overflow with no …).
    let r = Breadcrumb.segmentsToCollapse(
      widths: [20, 30, 30, 60], ellipsisWidth: ellipsis, separatorWidth: sep, available: 165)
    XCTAssertFalse(r.isEmpty)
  }
}
