import AppKit
import Foundation

final class PreviewContentLoader {
  struct Limits: Equatable {
    let maxHighlightedBytes: Int
    let maxPreviewBytes: Int

    static let production = Limits(
      maxHighlightedBytes: 5 * 1024 * 1024,
      maxPreviewBytes: 20 * 1024 * 1024
    )
  }

  struct ContentResult {
    let attributedString: NSAttributedString
    let wasHighlighted: Bool
    let wasTruncated: Bool
  }

  typealias Highlight = (String, PreviewFormat) throws -> NSAttributedString
  typealias Completion = (Result<ContentResult, Error>) -> Void

  private let queue = DispatchQueue(label: "dev.zest.preview-content", qos: .userInitiated)
  private let limits: Limits
  private let highlight: Highlight
  private var generation = 0

  init(
    limits: Limits = .production,
    highlight: @escaping Highlight = TreeSitterHighlighter.highlight
  ) {
    self.limits = limits
    self.highlight = highlight
  }

  @discardableResult
  func load(url: URL, format: PreviewFormat, completion: @escaping Completion) -> Int {
    generation += 1
    let requestGeneration = generation
    let limits = limits
    let highlight = highlight

    queue.async { [weak self] in
      let result = Result {
        try Self.buildResult(url: url, format: format, limits: limits, highlight: highlight)
      }
      DispatchQueue.main.async { [weak self] in
        guard let self,
          Self.shouldDeliver(
            requestGeneration: requestGeneration,
            currentGeneration: self.generation
          )
        else { return }
        completion(result)
      }
    }
    return requestGeneration
  }

  func invalidate() {
    generation += 1
  }

  static func shouldDeliver(requestGeneration: Int, currentGeneration: Int) -> Bool {
    requestGeneration == currentGeneration
  }

  static func buildResult(
    url: URL,
    format: PreviewFormat,
    limits: Limits,
    highlight: Highlight
  ) throws -> ContentResult {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true else {
      throw CocoaError(.fileReadUnsupportedScheme)
    }

    let fileSize = values.fileSize ?? 0
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }

    let requestedBytes = max(0, limits.maxPreviewBytes) + 1
    let data = try handle.read(upToCount: requestedBytes) ?? Data()
    let wasTruncated = fileSize > limits.maxPreviewBytes || data.count > limits.maxPreviewBytes
    let visibleData = data.prefix(max(0, limits.maxPreviewBytes))
    var source = String(decoding: visibleData, as: UTF8.self)
    if wasTruncated {
      source += "\n\n— Preview truncated at \(limits.maxPreviewBytes) bytes —\n"
    }

    let observedBytes = max(fileSize, data.count)
    let shouldHighlight = !wasTruncated && observedBytes <= limits.maxHighlightedBytes
    if shouldHighlight {
      return ContentResult(
        attributedString: try highlight(source, format),
        wasHighlighted: true,
        wasTruncated: false
      )
    }
    return ContentResult(
      attributedString: plainAttributedString(source),
      wasHighlighted: false,
      wasTruncated: wasTruncated
    )
  }

  private static func plainAttributedString(_ source: String) -> NSAttributedString {
    NSAttributedString(
      string: source,
      attributes: [
        .font: NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular),
        .foregroundColor: Theme.text,
      ]
    )
  }
}
