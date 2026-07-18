import Foundation

enum PreviewFormat: Equatable {
  case markdown
  case sema
  case json

  static func customFormat(for url: URL, isDirectory: Bool) -> PreviewFormat? {
    guard !isDirectory else { return nil }
    switch url.pathExtension.lowercased() {
    case "md", "markdown":
      return .markdown
    case "sema":
      return .sema
    case "json":
      return .json
    default:
      return nil
    }
  }
}
