import AppKit
import Foundation
import SwiftTreeSitter
import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterMarkdownInline
import TreeSitterSema

enum TreeSitterHighlighterError: Error, LocalizedError {
  case parseFailed(String)

  var errorDescription: String? {
    switch self {
    case .parseFailed(let language):
      return "Could not parse \(language) source"
    }
  }
}

enum HighlightQueryKind: CaseIterable {
  case json
  case sema
  case markdownBlock
  case markdownInline
}

enum TreeSitterHighlighter {
  private static let jsonLanguage = Language(language: tree_sitter_json())
  private static let semaLanguage = Language(language: tree_sitter_sema())
  private static let markdownBlockLanguage = Language(language: tree_sitter_markdown())
  private static let markdownInlineLanguage = Language(language: tree_sitter_markdown_inline())

  private static let jsonQuery: Result<Query, Error> = Result {
    try Query(language: jsonLanguage, data: EmbeddedHighlightQueries.json)
  }
  private static let semaQuery: Result<Query, Error> = Result {
    try Query(language: semaLanguage, data: EmbeddedHighlightQueries.sema)
  }
  private static let markdownBlockQuery: Result<Query, Error> = Result {
    try Query(language: markdownBlockLanguage, data: EmbeddedHighlightQueries.markdownBlock)
  }
  private static let markdownInlineQuery: Result<Query, Error> = Result {
    try Query(language: markdownInlineLanguage, data: EmbeddedHighlightQueries.markdownInline)
  }

  private static let captureColors: [String: NSColor] = [
    "keyword": Theme.syntaxKeyword,
    "string": Theme.syntaxString,
    "comment": Theme.syntaxComment,
    "number": Theme.syntaxNumber,
    "constant": Theme.syntaxConstant,
    "function": Theme.syntaxFunction,
    "punctuation": Theme.syntaxPunctuation,
    "operator": Theme.syntaxOperator,
    "variable": Theme.syntaxVariable,
    "escape": Theme.syntaxString,
    "text.title": Theme.syntaxMarkupHeading,
    "text.literal": Theme.syntaxString,
    "text.uri": Theme.syntaxMarkupReference,
    "text.reference": Theme.syntaxMarkupReference,
    "text.emphasis": Theme.syntaxString,
    "text.strong": Theme.syntaxMarkupHeading,
    "none": Theme.text,
  ]

  static func color(forCaptureName name: String) -> NSColor {
    var components = name.split(separator: ".").map(String.init)
    while !components.isEmpty {
      if let color = captureColors[components.joined(separator: ".")] {
        return color
      }
      components.removeLast()
    }
    return Theme.text
  }

  static func highlight(source: String, format: PreviewFormat) throws -> NSAttributedString {
    let attributed = NSMutableAttributedString(
      string: source,
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
        .foregroundColor: Theme.text,
      ]
    )

    let highlights: [NamedRange]
    switch format {
    case .json:
      highlights = try parse(
        source: source,
        language: jsonLanguage,
        queryKind: .json,
        displayName: "JSON"
      )
    case .sema:
      highlights = try parse(
        source: source,
        language: semaLanguage,
        queryKind: .sema,
        displayName: "Sema"
      )
    case .markdown:
      highlights = try markdownHighlights(source: source)
    }

    let sourceLength = source.utf16.count
    for highlight in highlights {
      let range = highlight.range
      guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= sourceLength else {
        continue
      }
      attributed.addAttribute(
        .foregroundColor,
        value: color(forCaptureName: highlight.name),
        range: range
      )
    }
    return attributed
  }

  private static func parse(
    source: String,
    language: Language,
    queryKind: HighlightQueryKind,
    displayName: String
  ) throws -> [NamedRange] {
    let parser = Parser()
    try parser.setLanguage(language)
    guard let tree = parser.parse(source) else {
      throw TreeSitterHighlighterError.parseFailed(displayName)
    }
    return try highlights(
      source: source,
      tree: tree,
      queryKind: queryKind
    )
  }

  static func query(for kind: HighlightQueryKind) throws -> Query {
    switch kind {
    case .json:
      return try jsonQuery.get()
    case .sema:
      return try semaQuery.get()
    case .markdownBlock:
      return try markdownBlockQuery.get()
    case .markdownInline:
      return try markdownInlineQuery.get()
    }
  }

  private static func highlights(
    source: String,
    tree: MutableTree,
    queryKind: HighlightQueryKind
  ) throws -> [NamedRange] {
    let cursor = try query(for: queryKind).execute(in: tree)
    return cursor.resolve(with: Predicate.Context(string: source)).highlights()
  }

  private static func markdownHighlights(source: String) throws -> [NamedRange] {
    let blockParser = Parser()
    try blockParser.setLanguage(markdownBlockLanguage)
    guard let blockTree = blockParser.parse(source), let root = blockTree.rootNode else {
      throw TreeSitterHighlighterError.parseFailed("Markdown")
    }

    var combined = try highlights(
      source: source,
      tree: blockTree,
      queryKind: .markdownBlock
    )

    let ranges = markdownInlineRanges(root: root)
    guard !ranges.isEmpty else { return combined }

    let inlineParser = Parser()
    try inlineParser.setLanguage(markdownInlineLanguage)
    inlineParser.includedRanges = ranges
    guard let inlineTree = inlineParser.parse(source) else {
      throw TreeSitterHighlighterError.parseFailed("Markdown inline")
    }
    combined.append(
      contentsOf: try highlights(
        source: source,
        tree: inlineTree,
        queryKind: .markdownInline
      )
    )
    return combined
  }

  private static func markdownInlineRanges(root: Node) -> [TSRange] {
    var ranges: [TSRange] = []

    func visit(_ node: Node) {
      if node.nodeType == "inline" || node.nodeType == "pipe_table_cell" {
        appendInlineSegments(for: node, to: &ranges)
        return
      }
      for index in 0..<node.childCount {
        if let child = node.child(at: index) {
          visit(child)
        }
      }
    }

    visit(root)
    return ranges.sorted()
  }

  private static func appendInlineSegments(for node: Node, to ranges: inout [TSRange]) {
    var startByte = node.byteRange.lowerBound
    var startPoint = node.pointRange.lowerBound

    for index in 0..<node.childCount {
      guard let child = node.child(at: index), child.isNamed else { continue }
      if startByte < child.byteRange.lowerBound {
        ranges.append(
          TSRange(
            points: startPoint..<child.pointRange.lowerBound,
            bytes: startByte..<child.byteRange.lowerBound
          )
        )
      }
      startByte = max(startByte, child.byteRange.upperBound)
      startPoint = max(startPoint, child.pointRange.upperBound)
    }

    if startByte < node.byteRange.upperBound {
      ranges.append(
        TSRange(
          points: startPoint..<node.pointRange.upperBound,
          bytes: startByte..<node.byteRange.upperBound
        )
      )
    }
  }
}
