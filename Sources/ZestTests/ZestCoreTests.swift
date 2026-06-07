import XCTest

@testable import Zest

final class ZestCoreTests: XCTestCase {
  private var indexPath: String {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("zest/index.zst").path
  }

  func testOpenAndQueryRealIndex() throws {
    guard FileManager.default.fileExists(atPath: indexPath) else {
      throw XCTSkip("No index at \(indexPath); run `zest-indexer --full-scan ~` first.")
    }
    let core = try XCTUnwrap(ZestCore(indexPath: indexPath))
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let rows = core.query("", scope: home, maxDepth: 1, maxResults: 5_000)
    XCTAssertFalse(rows.isEmpty, "home folder listing should return entries")
    XCTAssertFalse(rows[0].name.isEmpty)
  }

  func testOpenMissingFileReturnsNil() {
    XCTAssertNil(ZestCore(indexPath: "/nonexistent/zest/index.zst"))
  }

  // Ext breakdown sanity checks against the real on-disk index. These pin
  // the Swift veneer (String conversion, name padding) for both per-folder
  // (.folder, maxDepth=1) and subtree (.subfolders, maxDepth=.max) reads.
  // Skipped if the index is missing or the home folder is absent (e.g. in
  // a CI environment without a real ~).

  func testExtBreakdownPerFolderReturnsSortedRows() throws {
    guard FileManager.default.fileExists(atPath: indexPath) else {
      throw XCTSkip("No index at \(indexPath); run `zest-indexer --full-scan ~` first.")
    }
    let core = try XCTUnwrap(ZestCore(indexPath: indexPath))
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    // Cat 1 = images. Home folder typically has at least one image; if not,
    // skip rather than fail.
    let rows = core.extBreakdown(scope: home, maxDepth: 1, cat: 1, max: 8)
    guard !rows.isEmpty else {
      throw XCTSkip("Home folder has no images to test against.")
    }
    // Sorted by count desc.
    for i in 1..<rows.count {
      XCTAssertGreaterThanOrEqual(rows[i - 1].count, rows[i].count)
    }
    // No empty names.
    for row in rows {
      XCTAssertFalse(row.name.isEmpty, "ext breakdown should not return empty names")
    }
  }

  func testExtBreakdownSubtreeMergesAcrossFolders() throws {
    guard FileManager.default.fileExists(atPath: indexPath) else {
      throw XCTSkip("No index at \(indexPath); run `zest-indexer --full-scan ~` first.")
    }
    let core = try XCTUnwrap(ZestCore(indexPath: indexPath))
    // Root scope with .max depth should return at least as many exts as the
    // per-folder read for the home folder (the subtree includes the home
    // folder plus its descendants).
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let subtree = core.extBreakdown(scope: "/", maxDepth: .max, cat: 2, max: 32)
    let perFolder = core.extBreakdown(scope: home, maxDepth: 1, cat: 2, max: 32)
    XCTAssertGreaterThanOrEqual(subtree.count, perFolder.count)
  }

  func testExtBreakdownForMissingFolderReturnsEmpty() throws {
    guard FileManager.default.fileExists(atPath: indexPath) else {
      throw XCTSkip("No index at \(indexPath); run `zest-indexer --full-scan ~` first.")
    }
    let core = try XCTUnwrap(ZestCore(indexPath: indexPath))
    let rows = core.extBreakdown(scope: "/no/such/folder", maxDepth: 1, cat: 0, max: 8)
    XCTAssertTrue(rows.isEmpty)
  }

  func testExtBreakdownMaxZeroReturnsEmpty() throws {
    guard FileManager.default.fileExists(atPath: indexPath) else {
      throw XCTSkip("No index at \(indexPath); run `zest-indexer --full-scan ~` first.")
    }
    let core = try XCTUnwrap(ZestCore(indexPath: indexPath))
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    XCTAssertTrue(core.extBreakdown(scope: home, maxDepth: 1, cat: 0, max: 0).isEmpty)
  }
}
