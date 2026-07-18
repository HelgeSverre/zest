import XCTest

@testable import Zest

final class ZestCoreTests: XCTestCase {
  private var indexPath: String {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("zest/index.zst").path
  }

  /// These are optional integration checks against the developer's local
  /// index, not hermetic fixtures. A format bump intentionally makes an old
  /// index unreadable until the user chooses to rebuild it.
  private func requireCurrentLocalIndex() throws -> ZestCore {
    guard FileManager.default.fileExists(atPath: indexPath) else {
      throw XCTSkip("No index at \(indexPath); run `just index` first.")
    }
    guard let core = ZestCore(indexPath: indexPath) else {
      throw XCTSkip("Local index is unreadable or from an older format; run `just index`.")
    }
    return core
  }

  func testOpenAndQueryRealIndex() throws {
    let core = try requireCurrentLocalIndex()
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let rows = core.query("", scope: home, maxDepth: 1, maxResults: 5_000)
    // Skip if the home folder isn't in the index (e.g. the indexer was
    // run against a different scope like /tmp). This is an environmental
    // skip, not a failure.
    if rows.isEmpty {
      throw XCTSkip("Index doesn't cover \(home); re-run `zest-indexer --full-scan ~`.")
    }
    XCTAssertFalse(rows[0].name.isEmpty)
    // The core's stored identity must match what's currently on disk.
    XCTAssertEqual(
      core.fileIdentity, ZestCore.currentIdentity(of: indexPath),
      "core.fileIdentity should equal the on-disk identity immediately after open"
    )
  }

  func testOpenMissingFileReturnsNil() {
    XCTAssertNil(ZestCore(indexPath: "/nonexistent/zest/index.zst"))
  }

  func testIdentityChangesWhenFileReplaced() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("zest_identity_replace_\(UUID().uuidString).bin").path
    let data1 = Data(repeating: 0xAA, count: 128)
    try data1.write(to: URL(fileURLWithPath: tmp))
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let id1 = try XCTUnwrap(ZestCore.currentIdentity(of: tmp))

    // Remove and rewrite the same path so it gets a new inode and/or mtime.
    try FileManager.default.removeItem(atPath: tmp)
    let data2 = Data(repeating: 0xBB, count: 64)
    try data2.write(to: URL(fileURLWithPath: tmp))

    let id2 = try XCTUnwrap(ZestCore.currentIdentity(of: tmp))
    XCTAssertNotEqual(id1, id2, "Identity must change when the file is replaced at the same path")
  }

  func testCurrentIdentityNilForEmptyFile() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("zest_identity_empty_\(UUID().uuidString).bin").path
    // Write a zero-byte file.
    FileManager.default.createFile(atPath: tmp, contents: nil)
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    XCTAssertNil(
      ZestCore.currentIdentity(of: tmp),
      "currentIdentity should return nil for a zero-byte file"
    )
  }

  func testCurrentIdentityNonNilForExistingFile() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("zest_identity_test_\(UUID().uuidString).bin").path
    let data = Data(repeating: 0xAB, count: 64)
    try data.write(to: URL(fileURLWithPath: tmp))
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    let id = try XCTUnwrap(ZestCore.currentIdentity(of: tmp))
    XCTAssertEqual(id.size, 64)
    XCTAssertGreaterThan(id.inode, 0)
  }

  func testCurrentIdentityNilForMissingFile() {
    XCTAssertNil(ZestCore.currentIdentity(of: "/nonexistent/zest/index.zst"))
  }

  // Ext breakdown sanity checks against the real on-disk index. These pin
  // the Swift veneer (String conversion, name padding) for both per-folder
  // (.folder, maxDepth=1) and subtree (.subfolders, maxDepth=.max) reads.
  // Skipped if the index is missing or the home folder is absent (e.g. in
  // a CI environment without a real ~).

  func testExtBreakdownPerFolderReturnsSortedRows() throws {
    let core = try requireCurrentLocalIndex()
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
    let core = try requireCurrentLocalIndex()
    // Root scope with .max depth should return at least as many exts as the
    // per-folder read for the home folder (the subtree includes the home
    // folder plus its descendants).
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let subtree = core.extBreakdown(scope: "/", maxDepth: .max, cat: 2, max: 32)
    let perFolder = core.extBreakdown(scope: home, maxDepth: 1, cat: 2, max: 32)
    XCTAssertGreaterThanOrEqual(subtree.count, perFolder.count)
  }

  func testExtBreakdownForMissingFolderReturnsEmpty() throws {
    let core = try requireCurrentLocalIndex()
    let rows = core.extBreakdown(scope: "/no/such/folder", maxDepth: 1, cat: 0, max: 8)
    XCTAssertTrue(rows.isEmpty)
  }

  func testExtBreakdownMaxZeroReturnsEmpty() throws {
    let core = try requireCurrentLocalIndex()
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    XCTAssertTrue(core.extBreakdown(scope: home, maxDepth: 1, cat: 0, max: 0).isEmpty)
  }
}
