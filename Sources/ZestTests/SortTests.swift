import XCTest

@testable import Zest

/// "Folders on Top" pins directories before files regardless of the active
/// sort column/direction; within each group the column sort still applies.
final class FoldersOnTopSortTests: XCTestCase {
  private func row(_ name: String, dir: Bool, size: UInt64) -> ZestCore.Row {
    ZestCore.Row(
      name: name, dirPath: "/tmp", size: size, mtime: 0, kind: dir ? 1 : 0, category: 0)
  }

  func testSizeDescendingKeepsFoldersFirstWhenEnabled() {
    var rows = [
      row("big.bin", dir: false, size: 100),
      row("small-folder", dir: true, size: 5),
      row("tiny.txt", dir: false, size: 1),
      row("big-folder", dir: true, size: 10),
    ]
    AppCoordinator.applySort(to: &rows, column: .size, ascending: false, foldersOnTop: true)
    XCTAssertEqual(["big-folder", "small-folder", "big.bin", "tiny.txt"], rows.map(\.name))
  }

  func testSizeDescendingInterleavesWhenDisabled() {
    var rows = [
      row("big.bin", dir: false, size: 100),
      row("big-folder", dir: true, size: 10),
      row("tiny.txt", dir: false, size: 1),
    ]
    AppCoordinator.applySort(to: &rows, column: .size, ascending: false, foldersOnTop: false)
    XCTAssertEqual(["big.bin", "big-folder", "tiny.txt"], rows.map(\.name))
  }

  func testNameDescendingKeepsFoldersFirstWhenEnabled() {
    var rows = [
      row("zebra.txt", dir: false, size: 0),
      row("alpha", dir: true, size: 0),
      row("beta", dir: true, size: 0),
    ]
    AppCoordinator.applySort(to: &rows, column: .name, ascending: false, foldersOnTop: true)
    XCTAssertEqual(["beta", "alpha", "zebra.txt"], rows.map(\.name))
  }

  func testLegacyNameAscendingFoldersFirstUnchangedWhenDisabled() {
    var rows = [
      row("zebra.txt", dir: false, size: 0),
      row("alpha", dir: true, size: 0),
    ]
    AppCoordinator.applySort(to: &rows, column: .name, ascending: true, foldersOnTop: false)
    XCTAssertEqual(["alpha", "zebra.txt"], rows.map(\.name))
  }
}

final class FoldersOnTopPersistenceTests: XCTestCase {
  func testFoldersOnTopPersistsAcrossReloads() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("zest-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let state = UserState(directory: dir)
    XCTAssertFalse(state.foldersOnTop, "defaults to off")
    state.setFoldersOnTop(true)

    let reloaded = UserState(directory: dir)
    XCTAssertTrue(reloaded.foldersOnTop)
  }
}
