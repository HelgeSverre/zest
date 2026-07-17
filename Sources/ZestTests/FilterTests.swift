import XCTest

@testable import Zest

/// Round-trip + parser tests for `Filter`, the structured (category, extensions,
/// text) form that replaced the stringly-typed `queryText`. The parser mirrors
/// the Zig `query_parser` tokenize-on-space behaviour so a freeform
/// `queryText` round-trips losslessly.
final class FilterTests: XCTestCase {
  func testEmpty() {
    let f = Filter.parse("")
    XCTAssertNil(f.category)
    XCTAssertTrue(f.extensions.isEmpty)
    XCTAssertEqual("", f.text)
    XCTAssertEqual("", f.encoded)
    XCTAssertTrue(f.isEmpty)
  }

  func testPlainText() {
    let f = Filter.parse("report")
    XCTAssertNil(f.category)
    XCTAssertEqual("report", f.text)
    XCTAssertEqual("report", f.encoded)
  }

  func testCategoryOnly() {
    let f = Filter.parse("cat:code")
    XCTAssertEqual("code", f.category)
    XCTAssertEqual("", f.text)
    XCTAssertEqual("cat:code", f.encoded)
  }

  func testCategoryAndExtension() {
    let f = Filter.parse("cat:code ext:rs")
    XCTAssertEqual("code", f.category)
    XCTAssertEqual(["rs"], f.extensions)
    XCTAssertEqual("cat:code ext:rs", f.encoded)
  }

  func testCategoryExtensionAndText() {
    let f = Filter.parse("cat:code ext:rs fmt")
    XCTAssertEqual("code", f.category)
    XCTAssertEqual(["rs"], f.extensions)
    XCTAssertEqual("fmt", f.text)
    XCTAssertEqual("cat:code ext:rs fmt", f.encoded)
  }

  func testMultipleTextWords() {
    let f = Filter.parse("hello world")
    XCTAssertEqual("hello world", f.text)
    XCTAssertEqual("hello world", f.encoded)
  }

  func testUnknownQualifierStaysAsText() {
    // Mirrors the Zig parser: `foo:bar` is not a recognized qualifier, so it
    // falls into the text bucket. Users sometimes type things that look like
    // qualifiers; we shouldn't silently drop them.
    let f = Filter.parse("foo:bar hello")
    XCTAssertEqual("foo:bar hello", f.text)
    XCTAssertNil(f.category)
    XCTAssertTrue(f.extensions.isEmpty)
  }

  func testCategoryIsLowercased() {
    // The engine matches cat: keys case-insensitively; we normalize to
    // lowercase so the sidebar's `filter.category == meta.queryKey` check
    // works regardless of how the user typed it.
    let f = Filter.parse("Cat:CODE")
    XCTAssertEqual("code", f.category)
  }

  func testExtensionIsLowercased() {
    let f = Filter.parse("ext:PDF")
    XCTAssertEqual(["pdf"], f.extensions)
  }

  func testExtensionWithEmptyValueIsIgnored() {
    let f = Filter.parse("ext:")
    XCTAssertTrue(f.extensions.isEmpty)
  }

  func testCategoryWithEmptyValueIsIgnored() {
    let f = Filter.parse("cat:")
    XCTAssertNil(f.category)
  }

  func testEncodedStableOrdering() {
    // The sidebar's click handler relies on a predictable encoded form for
    // tests + diffing. cat first, then ext sorted, then text.
    let f = Filter(
      category: "code",
      extensions: ["zig", "rs"],
      text: "fmt",
    )
    XCTAssertEqual("cat:code ext:rs ext:zig fmt", f.encoded)
  }

  func testRoundTripLossless() {
    // Property: for any (category, extensions, text), encoding then parsing
    // returns the same Filter. The sidebar's click handlers depend on this.
    let cases: [Filter] = [
      .init(),
      .init(category: "code"),
      .init(category: "images", extensions: ["png", "jpg"]),
      .init(text: "report"),
      .init(category: "documents", extensions: ["pdf"], text: "quarterly"),
      .init(text: "hello world"),
      .init(extensions: ["php,html"], text: "report"),  // comma OR-list stays opaque
    ]
    for original in cases {
      let roundTripped = Filter.parse(original.encoded)
      XCTAssertEqual(original, roundTripped, "round-trip lost data for \(original.encoded)")
    }
  }

  func testCommaExtensionListStaysOneElement() {
    // `ext:php,html` is the engine's OR syntax; Swift treats the value as
    // opaque — one set element, no splitting — so the typed query round-trips
    // and the engine (filters.zig) does the comma semantics.
    let f = Filter.parse("car ext:PHP,html")
    XCTAssertEqual(["php,html"], f.extensions)
    XCTAssertEqual("car", f.text)
    XCTAssertEqual("ext:php,html car", f.encoded)
  }

  func testNegatedExtensionStaysAsText() {
    // `!ext:` is engine syntax Swift's chip model doesn't represent; it must
    // ride through the text bucket verbatim so the engine still sees it.
    let f = Filter.parse("!ext:php,html report")
    XCTAssertTrue(f.extensions.isEmpty)
    XCTAssertEqual("!ext:php,html report", f.text)
  }
}

/// Tests for `SearchField.refreshDecision`, the guard that keeps `refresh()`
/// from rewriting the field with canonicalized text while the user is typing
/// (the coordinator lags the field by the 150ms debounce), while still letting
/// external mutations (saved filter applied, navigation reset) sync a focused
/// field.
final class SearchFieldRefreshDecisionTests: XCTestCase {
  func testEchoOfOwnCommitSkipsWhileTyping() {
    // The coordinator holds exactly what we last committed (canonicalized) —
    // refresh must not touch the field.
    let decision = SearchField.refreshDecision(
      focused: true, lastCommitted: "ext:wh", current: Filter.parse("ext:wh"))
    XCTAssertEqual(SearchField.RefreshDecision.skipWhileTyping, decision)
  }

  func testEchoDetectionIsSemanticNotTextual() {
    // The field's literal text ("Report ext:PDF") differs from the canonical
    // form ("ext:pdf Report") — still the same Filter, still an echo.
    let decision = SearchField.refreshDecision(
      focused: true, lastCommitted: "Report ext:PDF", current: Filter.parse("ext:pdf Report"))
    XCTAssertEqual(SearchField.RefreshDecision.skipWhileTyping, decision)
  }

  func testExternalChangeSyncsEvenWhileFocused() {
    // A saved filter was applied while the field had focus: coordinator state
    // no longer matches our last commit — the field must update.
    let decision = SearchField.refreshDecision(
      focused: true, lastCommitted: "ext:wh", current: Filter.parse("cat:video size:>100mb"))
    XCTAssertEqual(SearchField.RefreshDecision.syncFromCoordinator, decision)
  }

  func testNavigationResetSyncsEvenWhileFocused() {
    let decision = SearchField.refreshDecision(
      focused: true, lastCommitted: "ext:wha", current: Filter.parse(""))
    XCTAssertEqual(SearchField.RefreshDecision.syncFromCoordinator, decision)
  }

  func testUnfocusedAlwaysSyncs() {
    let decision = SearchField.refreshDecision(
      focused: false, lastCommitted: "ext:wh", current: Filter.parse("ext:wh"))
    XCTAssertEqual(SearchField.RefreshDecision.syncFromCoordinator, decision)
  }
}

/// Tests for the sidebar's extension-row click semantics: plain click
/// replaces, ⌘/⌃-click toggles the extension in the OR-set the engine
/// supports, and cross-category multi-select drops the category filter
/// (keeping it would AND-exclude the other categories' files).
final class SidebarExtClickTests: XCTestCase {
  func testPlainClickReplacesSelection() {
    let r = SidebarViewController.extClickResult(
      current: Filter(category: "images", extensions: ["png"]),
      clickedExt: "zig", clickedCategory: "code", additive: false)
    XCTAssertEqual("code", r.category)
    XCTAssertEqual(["zig"], r.extensions)
  }

  func testPlainClickOnSoleActiveExtTogglesOff() {
    let r = SidebarViewController.extClickResult(
      current: Filter(category: "code", extensions: ["zig"]),
      clickedExt: "zig", clickedCategory: "code", additive: false)
    XCTAssertEqual("code", r.category, "clearing the ext keeps the category")
    XCTAssertTrue(r.extensions.isEmpty)
  }

  func testPlainClickWithMultiSelectionCollapsesToClicked() {
    let r = SidebarViewController.extClickResult(
      current: Filter(category: "code", extensions: ["zig", "rs"]),
      clickedExt: "zig", clickedCategory: "code", additive: false)
    XCTAssertEqual(["zig"], r.extensions)
  }

  func testAdditiveClickAccumulatesWithinCategory() {
    let r = SidebarViewController.extClickResult(
      current: Filter(category: "code", extensions: ["zig"]),
      clickedExt: "rs", clickedCategory: "code", additive: true)
    XCTAssertEqual("code", r.category)
    XCTAssertEqual(["zig", "rs"], r.extensions)
  }

  func testAdditiveClickAcrossCategoriesDropsCategory() {
    let r = SidebarViewController.extClickResult(
      current: Filter(category: "code", extensions: ["zig"]),
      clickedExt: "png", clickedCategory: "images", additive: true)
    XCTAssertNil(r.category, "cat:code AND ext:png would exclude the zig files")
    XCTAssertEqual(["zig", "png"], r.extensions)
  }

  func testAdditiveClickOnActiveExtRemovesIt() {
    let r = SidebarViewController.extClickResult(
      current: Filter(category: "code", extensions: ["zig", "rs"]),
      clickedExt: "zig", clickedCategory: "code", additive: true)
    XCTAssertEqual("code", r.category)
    XCTAssertEqual(["rs"], r.extensions)
  }

  func testAdditiveFirstSelectionBehavesLikePlainClick() {
    let r = SidebarViewController.extClickResult(
      current: Filter(),
      clickedExt: "zig", clickedCategory: "code", additive: true)
    XCTAssertEqual("code", r.category)
    XCTAssertEqual(["zig"], r.extensions)
  }

  func testExtIsSelectedMatchesCommaListElements() {
    XCTAssertTrue(SidebarViewController.extIsSelected("php", in: ["php"]))
    XCTAssertTrue(SidebarViewController.extIsSelected("php", in: ["php,html"]))
    XCTAssertTrue(SidebarViewController.extIsSelected("html", in: ["php,html", "zig"]))
    XCTAssertFalse(SidebarViewController.extIsSelected("css", in: ["php,html"]))
    XCTAssertFalse(SidebarViewController.extIsSelected("php", in: []))
  }
}

/// Tests for the `scopeRoot` / `scopeDepth` getters on `AppCoordinator`. They
/// are the single source of truth for the file list AND the sidebar's
/// histogram — a divergence here is exactly what caused the recursive
/// counting bug.
final class AppCoordinatorScopeTests: XCTestCase {
  private var home: String {
    FileManager.default.homeDirectoryForCurrentUser.path
  }

  func testFolderScopeUsesCurrentPathAndDepthOne() {
    let c = AppCoordinator()
    c.navigate(to: home)  // sets currentPath + resets query/scope to defaults
    XCTAssertEqual(home, c.currentPath)
    XCTAssertEqual(AppCoordinator.Scope.folder, c.scope)
    XCTAssertEqual(home, c.scopeRoot)
    XCTAssertEqual(UInt32(1), c.scopeDepth)
  }

  func testSubfoldersScopeUsesCurrentPathAndMaxDepth() {
    let c = AppCoordinator()
    c.navigate(to: home)
    c.scope = .subfolders
    XCTAssertEqual(home, c.scopeRoot)
    XCTAssertEqual(UInt32.max, c.scopeDepth)
  }

  func testEverywhereScopeUsesRootAndMaxDepth() {
    let c = AppCoordinator()
    c.navigate(to: home)
    c.scope = .everywhere
    XCTAssertEqual("/", c.scopeRoot)
    XCTAssertEqual(UInt32.max, c.scopeDepth)
  }

  func testFilterMutationPreservesTextOnCategoryToggle() {
    // Simulates the sidebar's category click handler: setting `category` to
    // a new value should NOT clobber the search text. Pre-fix the click
    // handler overwrote the entire queryText, losing any plain text the
    // user had typed.
    let c = AppCoordinator()
    c.queryText = "quarterly"
    XCTAssertEqual("quarterly", c.filter.text)

    c.filter.category = "documents"
    XCTAssertEqual("documents", c.filter.category)
    XCTAssertEqual("quarterly", c.filter.text, "category toggle should not clear text")
    XCTAssertEqual("cat:documents quarterly", c.queryText)
  }

  func testFilterMutationPreservesCategoryOnExtensionToggle() {
    let c = AppCoordinator()
    c.filter.category = "code"
    c.filter.text = "fmt"

    c.filter.extensions = ["rs"]
    XCTAssertEqual("code", c.filter.category, "ext toggle should not clear category")
    XCTAssertEqual("fmt", c.filter.text, "ext toggle should not clear text")
    XCTAssertEqual("cat:code ext:rs fmt", c.queryText)
  }

  func testFilterCategoryToggleOffClearsCategoryOnly() {
    let c = AppCoordinator()
    c.queryText = "cat:code ext:rs fmt"

    c.filter.category = nil
    XCTAssertNil(c.filter.category)
    XCTAssertEqual(["rs"], c.filter.extensions, "clearing category should not touch ext")
    XCTAssertEqual("fmt", c.filter.text, "clearing category should not touch text")
    XCTAssertEqual("ext:rs fmt", c.queryText)
  }

  func testFilterExtensionToggleOffClearsExtensionOnly() {
    let c = AppCoordinator()
    c.queryText = "cat:code ext:rs fmt"

    c.filter.extensions.remove("rs")
    XCTAssertEqual("code", c.filter.category)
    XCTAssertTrue(c.filter.extensions.isEmpty)
    XCTAssertEqual("fmt", c.filter.text)
    XCTAssertEqual("cat:code fmt", c.queryText)
  }
}
