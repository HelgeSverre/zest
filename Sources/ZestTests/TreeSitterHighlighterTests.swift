import AppKit
import XCTest

@testable import Zest

final class TreeSitterHighlighterTests: XCTestCase {
  func testCustomFormatRoutesSupportedRegularFilesCaseInsensitively() {
    XCTAssertEqual(
      PreviewFormat.customFormat(for: URL(fileURLWithPath: "/tmp/README.MD"), isDirectory: false),
      .markdown)
    XCTAssertEqual(
      PreviewFormat.customFormat(for: URL(fileURLWithPath: "/tmp/model.sema"), isDirectory: false),
      .sema)
    XCTAssertEqual(
      PreviewFormat.customFormat(for: URL(fileURLWithPath: "/tmp/data.json"), isDirectory: false),
      .json)
  }

  func testCustomFormatRejectsDirectoriesAndUnsupportedFiles() {
    XCTAssertNil(
      PreviewFormat.customFormat(for: URL(fileURLWithPath: "/tmp/folder.md"), isDirectory: true))
    XCTAssertNil(
      PreviewFormat.customFormat(for: URL(fileURLWithPath: "/tmp/image.png"), isDirectory: false))
  }

  func testCaptureColorsUseHierarchicalFallbacks() {
    XCTAssertEqual(
      TreeSitterHighlighter.color(forCaptureName: "function.builtin"), Theme.syntaxFunction)
    XCTAssertEqual(
      TreeSitterHighlighter.color(forCaptureName: "string.special.key"), Theme.syntaxString)
    XCTAssertEqual(
      TreeSitterHighlighter.color(forCaptureName: "punctuation.bracket"), Theme.syntaxPunctuation)
    XCTAssertEqual(TreeSitterHighlighter.color(forCaptureName: "unknown.capture"), Theme.text)
  }

  func testJSONParseColorsKeysAndNumbers() throws {
    let source = #"{"answer": 42}"#
    let highlighted = try TreeSitterHighlighter.highlight(source: source, format: .json)

    XCTAssertEqual(color(in: highlighted, at: 2), Theme.syntaxString)
    XCTAssertEqual(color(in: highlighted, at: 11), Theme.syntaxNumber)
  }

  func testSemaParseColorsBuiltinsAndStrings() throws {
    let source = #"(println "hello")"#
    let highlighted = try TreeSitterHighlighter.highlight(source: source, format: .sema)

    XCTAssertEqual(color(in: highlighted, at: 2), Theme.syntaxFunction)
    XCTAssertEqual(color(in: highlighted, at: 10), Theme.syntaxString)
  }

  func testMarkdownParseColorsBlockAndInlineSyntax() throws {
    let source = "# Title\n\nRead [the docs](https://example.com).\n"
    let highlighted = try TreeSitterHighlighter.highlight(source: source, format: .markdown)

    XCTAssertEqual(color(in: highlighted, at: 2), Theme.syntaxMarkupHeading)
    XCTAssertEqual(color(in: highlighted, at: 16), Theme.syntaxMarkupReference)
  }

  private func color(in string: NSAttributedString, at index: Int) -> NSColor? {
    string.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
  }
}
