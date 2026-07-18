import Foundation

enum QueryResourceLoaderError: Error, LocalizedError {
  case missingHighlightsQuery(String)

  var errorDescription: String? {
    switch self {
    case .missingHighlightsQuery(let bundleName):
      return "Could not find highlights.scm in \(bundleName).bundle"
    }
  }
}

enum QueryResourceLoader {
  static func highlightsURL(bundleName: String) throws -> URL {
    let fileManager = FileManager.default
    let bundleDirectoryName = "\(bundleName).bundle"
    var roots: [URL] = []

    func addRoot(_ url: URL?) {
      guard let url else { return }
      let standardized = url.standardizedFileURL
      if !roots.contains(where: { $0.path == standardized.path }) {
        roots.append(standardized)
      }
    }

    addRoot(Bundle.main.resourceURL)
    addRoot(Bundle.main.bundleURL)
    addRoot(Bundle.main.bundleURL.deletingLastPathComponent())

    for bundle in Bundle.allBundles + Bundle.allFrameworks {
      addRoot(bundle.resourceURL)
      addRoot(bundle.bundleURL)
      addRoot(bundle.bundleURL.deletingLastPathComponent())
    }

    if let executable = ProcessInfo.processInfo.arguments.first {
      var directory = URL(fileURLWithPath: executable).deletingLastPathComponent()
      for _ in 0..<5 {
        addRoot(directory)
        directory.deleteLastPathComponent()
      }
    }

    for root in roots {
      let bundleURL =
        root.lastPathComponent == bundleDirectoryName
        ? root : root.appendingPathComponent(bundleDirectoryName, isDirectory: true)
      let candidates = [
        bundleURL.appendingPathComponent("queries/highlights.scm"),
        bundleURL.appendingPathComponent("Contents/Resources/queries/highlights.scm"),
      ]
      if let match = candidates.first(where: { fileManager.isReadableFile(atPath: $0.path) }) {
        return match
      }
    }

    throw QueryResourceLoaderError.missingHighlightsQuery(bundleName)
  }
}
