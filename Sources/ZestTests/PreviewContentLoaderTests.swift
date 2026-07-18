import AppKit
import XCTest

@testable import Zest

final class PreviewContentLoaderTests: XCTestCase {
  func testFileAtHighlightLimitUsesHighlighter() throws {
    let url = try temporaryFile(data: Data("1234".utf8))
    defer { try? FileManager.default.removeItem(at: url) }
    var highlighted = false

    let result = try PreviewContentLoader.buildResult(
      url: url,
      format: .json,
      limits: .init(maxHighlightedBytes: 4, maxPreviewBytes: 8)
    ) { source, _ in
      highlighted = true
      return NSAttributedString(string: source)
    }

    XCTAssertTrue(highlighted)
    XCTAssertTrue(result.wasHighlighted)
    XCTAssertFalse(result.wasTruncated)
  }

  func testFileAboveHighlightLimitUsesPlainText() throws {
    let url = try temporaryFile(data: Data("12345".utf8))
    defer { try? FileManager.default.removeItem(at: url) }

    let result = try PreviewContentLoader.buildResult(
      url: url,
      format: .json,
      limits: .init(maxHighlightedBytes: 4, maxPreviewBytes: 8)
    ) { _, _ in
      XCTFail("Files above the highlight limit must not be parsed")
      return NSAttributedString()
    }

    XCTAssertFalse(result.wasHighlighted)
    XCTAssertFalse(result.wasTruncated)
    XCTAssertEqual(result.attributedString.string, "12345")
  }

  func testFileAbovePreviewLimitIsTruncatedWithNotice() throws {
    let url = try temporaryFile(data: Data("123456789".utf8))
    defer { try? FileManager.default.removeItem(at: url) }

    let result = try PreviewContentLoader.buildResult(
      url: url,
      format: .markdown,
      limits: .init(maxHighlightedBytes: 4, maxPreviewBytes: 8)
    ) { _, _ in
      XCTFail("Truncated files must not be parsed")
      return NSAttributedString()
    }

    XCTAssertTrue(result.wasTruncated)
    XCTAssertTrue(result.attributedString.string.hasPrefix("12345678"))
    XCTAssertTrue(result.attributedString.string.contains("Preview truncated"))
  }

  func testMalformedUTF8IsReplacedInsteadOfFailing() throws {
    let url = try temporaryFile(data: Data([0xFF, 0x41]))
    defer { try? FileManager.default.removeItem(at: url) }

    let result = try PreviewContentLoader.buildResult(
      url: url,
      format: .sema,
      limits: .init(maxHighlightedBytes: 0, maxPreviewBytes: 8)
    ) { _, _ in NSAttributedString() }

    XCTAssertEqual(result.attributedString.string, "�A")
  }

  func testMissingFileThrows() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    XCTAssertThrowsError(
      try PreviewContentLoader.buildResult(
        url: url,
        format: .json,
        limits: .init(maxHighlightedBytes: 4, maxPreviewBytes: 8)
      ) { _, _ in NSAttributedString() }
    )
  }

  func testOnlyCurrentGenerationIsDeliverable() {
    XCTAssertTrue(PreviewContentLoader.shouldDeliver(requestGeneration: 4, currentGeneration: 4))
    XCTAssertFalse(PreviewContentLoader.shouldDeliver(requestGeneration: 3, currentGeneration: 4))
  }

  private func temporaryFile(data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try data.write(to: url)
    return url
  }
}
