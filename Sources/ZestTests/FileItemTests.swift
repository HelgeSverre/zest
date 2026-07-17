import XCTest

@testable import Zest

/// Folder rows show their recursive subtree size (baked into the index's
/// size column by the v4 builder) instead of the old "—" placeholder.
final class FileItemSizeTextTests: XCTestCase {
  private func makeItem(isDirectory: Bool, size: UInt64) -> FileItem {
    FileItem(
      name: isDirectory ? "docs" : "a.txt", path: "/tmp/x", dirPath: "/tmp",
      isDirectory: isDirectory, size: size, mtime: 0,
      kindLabel: "", kindColor: .white, symbol: "doc", symbolColor: .white,
      extText: "—")
  }

  func testDirectorySizeTextFormatsSubtreeSize() {
    let dir = makeItem(isDirectory: true, size: 8192)
    let file = makeItem(isDirectory: false, size: 8192)
    XCTAssertEqual(file.sizeText, dir.sizeText, "folders format like files now")
    XCTAssertFalse(dir.sizeText.contains("—"))
  }
}
