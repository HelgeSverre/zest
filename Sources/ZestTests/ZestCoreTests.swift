import XCTest

@testable import Zest

final class ZestCoreTests: XCTestCase {
  private var developerIndexPath: String {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("zest/index.zst").path
  }

  private var configuredIndexPath: String? {
    ProcessInfo.processInfo.environment["ZEST_TEST_INDEX_PATH"]
  }

  private var integrationIndexPath: String {
    configuredIndexPath ?? developerIndexPath
  }

  private var integrationScope: String {
    ProcessInfo.processInfo.environment["ZEST_TEST_INDEX_SCOPE"]
      ?? FileManager.default.homeDirectoryForCurrentUser.path
  }

  /// CI supplies a generated fixture and must fail if it is absent or stale.
  /// Without that explicit configuration these remain optional checks against
  /// the developer's local index.
  private func requireIntegrationIndex() throws -> ZestCore {
    if configuredIndexPath != nil {
      return try XCTUnwrap(
        ZestCore(indexPath: integrationIndexPath),
        "Configured fixture index is missing, empty, or incompatible: \(integrationIndexPath)")
    }
    guard FileManager.default.fileExists(atPath: integrationIndexPath) else {
      throw XCTSkip("No index at \(integrationIndexPath); run `just index` first.")
    }
    guard let core = ZestCore(indexPath: integrationIndexPath) else {
      throw XCTSkip("Local index is unreadable or from an older format; run `just index`.")
    }
    return core
  }

  func testOpenAndQueryRealIndex() throws {
    let core = try requireIntegrationIndex()
    let rows = core.query("", scope: integrationScope, maxDepth: 1, maxResults: 5_000)
    if rows.isEmpty {
      if configuredIndexPath != nil {
        XCTFail("Configured fixture index does not cover \(integrationScope)")
        return
      }
      throw XCTSkip(
        "Index doesn't cover \(integrationScope); re-run `zest-indexer --full-scan ~`.")
    }
    XCTAssertFalse(rows[0].name.isEmpty)
    // The core's stored identity must match what's currently on disk.
    XCTAssertEqual(
      core.fileIdentity, ZestCore.currentIdentity(of: integrationIndexPath),
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
  // Developer-local checks may skip for missing data; configured CI fixtures
  // are mandatory and fail if representative data is absent.

  func testExtBreakdownPerFolderReturnsSortedRows() throws {
    let core = try requireIntegrationIndex()
    let rows = core.extBreakdown(scope: integrationScope, maxDepth: 1, cat: 1, max: 8)
    guard !rows.isEmpty else {
      if configuredIndexPath != nil {
        XCTFail("Configured fixture scope has no direct image files")
        return
      }
      throw XCTSkip("Integration scope has no direct image files.")
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
    let core = try requireIntegrationIndex()
    let subtree = core.extBreakdown(scope: integrationScope, maxDepth: .max, cat: 2, max: 32)
    let perFolder = core.extBreakdown(scope: integrationScope, maxDepth: 1, cat: 2, max: 32)
    XCTAssertGreaterThanOrEqual(subtree.count, perFolder.count)
  }

  func testExtBreakdownForMissingFolderReturnsEmpty() throws {
    let core = try requireIntegrationIndex()
    let rows = core.extBreakdown(scope: "/no/such/folder", maxDepth: 1, cat: 0, max: 8)
    XCTAssertTrue(rows.isEmpty)
  }

  func testExtBreakdownMaxZeroReturnsEmpty() throws {
    let core = try requireIntegrationIndex()
    XCTAssertTrue(
      core.extBreakdown(scope: integrationScope, maxDepth: 1, cat: 0, max: 0).isEmpty)
  }

  func testHistogramReturnsAllCategories() throws {
    let core = try requireIntegrationIndex()
    let counts = core.histogram(scope: integrationScope, maxDepth: .max)
    XCTAssertEqual(counts.count, 9)
    if configuredIndexPath != nil {
      XCTAssertGreaterThan(counts[1], 0, "fixture must include an image")
      XCTAssertGreaterThan(counts[3], 0, "fixture must include a document")
      XCTAssertGreaterThan(counts[7], 0, "fixture must include code")
    }
  }
}
