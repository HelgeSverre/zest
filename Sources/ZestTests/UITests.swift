import AppKit
import XCTest

@testable import Zest

/// Headless AppKit UI tests: the real window, real key/mouse events, asserted
/// through coordinator state plus what the views show. Skips without an index
/// (same rule as `ZestCoreTests`).
final class UITests: XCTestCase {
  private var ui: UIHarness!

  override func setUpWithError() throws {
    ui = try UIHarness.make()
    ui.settle()
  }

  override func tearDown() { ui = nil }

  func testTypingSearchShowsResultsInTable() throws {
    try ui.type("readme")
    ui.settle()
    XCTAssertEqual(ui.coordinator.queryText, "readme")
    XCTAssertEqual(ui.coordinator.scope, .subfolders)
    let table: NSTableView = try ui.require(A11y.browserTable)
    let results = ui.coordinator.results()
    XCTAssertEqual(table.numberOfRows, results.count)
    if let first = results.first {
      XCTAssertEqual(ui.browserCellText(row: 0), first.name)
    }
  }

  func testEscapeBlursSearchAndDeleteClearsQuery() throws {
    try ui.type("readme")
    ui.settle()
    let field: NSTextField = try ui.require(A11y.search)
    XCTAssertTrue(field.currentEditor() != nil, "typing should leave the field editing")

    // Esc leaves the field; the query is kept (SearchField's documented behaviour).
    ui.press(.escape)
    XCTAssertNil(field.currentEditor())
    XCTAssertEqual(ui.coordinator.queryText, "readme")

    // Deleting the text is what empties the query.
    ui.window.makeFirstResponder(field)
    ui.press(.escape)  // no-op guard: Esc must not clear text either
    ui.window.makeFirstResponder(field)
    field.currentEditor()?.selectAll(nil)
    ui.press(.delete)
    ui.settle()
    XCTAssertEqual(field.stringValue, "")
    XCTAssertEqual(ui.coordinator.queryText, "")
    XCTAssertEqual(ui.coordinator.scope, .subfolders, "clearing text keeps the scope")

    // "This folder" chip returns to browse mode.
    ui.click(try ui.require(A11y.filterScope(.folder)))
    ui.settle()
    XCTAssertFalse(ui.coordinator.isSearchMode)
    XCTAssertEqual(ui.coordinator.scope, .folder)
  }

  func testCommandUpNavigatesToParent() throws {
    let start = ui.coordinator.currentPath
    let folder = try XCTUnwrap(ui.coordinator.results().first { $0.kind == 1 }, "need a subfolder")
    ui.arm()
    XCTAssertTrue(ui.coordinator.navigate(to: folder.dirPath + "/" + folder.name))
    ui.settle()
    XCTAssertNotEqual(ui.coordinator.currentPath, start)
    ui.press(.up, modifiers: [.command])
    ui.settle()
    // `goUp` standardizes the path (e.g. /private/tmp → /tmp); compare like for like.
    XCTAssertEqual(ui.coordinator.currentPath, (start as NSString).standardizingPath)
  }

  func testDoubleClickingFolderRowNavigatesInto() throws {
    let results = ui.coordinator.results()
    let row = try XCTUnwrap(results.firstIndex { $0.kind == 1 }, "need a subfolder row")
    let folder = results[row]
    try ui.clickRow(row, double: true)
    ui.settle()
    let expected = ((folder.dirPath + "/" + folder.name) as NSString).standardizingPath
    XCTAssertEqual(ui.coordinator.currentPath, expected)
    XCTAssertEqual(ui.coordinator.queryText, "")
  }

  func testClickingSidebarCategorySetsFilter() throws {
    ui.click(try ui.require(A11y.sidebarCategory("code")))
    ui.settle()
    XCTAssertEqual(ui.coordinator.filter.category, "code")
    XCTAssertEqual(ui.coordinator.queryText, "cat:code")
    XCTAssertTrue(ui.coordinator.isSearchMode)
    XCTAssertTrue(ui.coordinator.results().allSatisfy { $0.kind != 1 && $0.category == 7 })
  }

  func testTogglingScopeChipChangesResults() throws {
    let folderCount = ui.coordinator.results().count
    ui.click(try ui.require(A11y.filterScope(.subfolders)))
    ui.settle()
    XCTAssertEqual(ui.coordinator.scope, .subfolders)
    XCTAssertTrue(ui.coordinator.isSearchMode)
    // The subtree is a superset of the folder listing (capped at maxResults).
    XCTAssertGreaterThanOrEqual(ui.coordinator.results().count, folderCount)
    ui.click(try ui.require(A11y.filterScope(.folder)))
    ui.settle()
    XCTAssertEqual(ui.coordinator.scope, .folder)
    XCTAssertEqual(ui.coordinator.results().count, folderCount)
  }

  func testStatusBarReflectsLandedQuery() throws {
    let count: NSTextField = try ui.require(A11y.statusCount)
    let selection: NSTextField = try ui.require(A11y.statusSelection)
    XCTAssertFalse(count.stringValue.isEmpty)
    try ui.type("readme")
    ui.settle()
    let first = try XCTUnwrap(ui.coordinator.results().first, "no 'readme' in index")
    XCTAssertTrue(
      selection.stringValue.hasPrefix(first.name + " — "),
      "status bar should summarize row 0: \(selection.stringValue)")
  }
}
