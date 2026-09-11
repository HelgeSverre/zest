import AppKit

/// Parsed `Zest` command line. Kept free of AppKit side effects so it is testable
/// and so the "what to do with a path" decision lives in one place (main.swift).
enum LaunchAction: Equatable {
  /// Open the browser; `path` is an absolute directory or nil for `$HOME`.
  case browse(path: String?)
  case help
  case version
  /// `status` or `uninstall` against the bundled SMAppService agent.
  case indexer(command: String)
  case snapshot(path: String, size: NSSize)
  case bench(iterations: Int, json: Bool)
}

enum LaunchOptions {
  static let name = "zest"

  static let usage = """
    Usage: zest [PATH]
           zest [OPTIONS]

    Open the Zest file browser. PATH is a folder to start in (relative paths
    resolve against the current directory); defaults to your home folder.

    Options:
      -h, --help               Show this help
      -V, --version            Print version and exit

    Diagnostics:
      --indexer-status         Print the bundled indexer service state and exit
      --indexer-uninstall      Unregister the bundled indexer service and exit
      --snapshot PNG [WxH]     Render the UI off-screen to PNG and exit (dev)
      --bench [--iterations N] [--json]
                               Benchmark the UI headlessly against the index and exit (dev)

    Examples:
      zest .
      zest ~/Downloads
      zest --indexer-status

    """

  /// "Zest 0.1.1 (build 2)" from the bundle's Info.plist; `swift run` builds
  /// have no bundle and report 0.0.0-dev.
  static var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    let build = (info?["CFBundleVersion"] as? String).map { " (build \($0))" } ?? ""
    return "Zest \(short)\(build)"
  }

  /// `args` excludes argv[0]. `cwd` anchors relative PATHs. Errors are
  /// user-facing messages (exit 2 for usage errors, 1 for a bad path).
  static func parse(_ args: [String], cwd: String) -> Result<LaunchAction, LaunchError> {
    var path: String?
    var bench = false
    var iterations = 7
    var json = false
    var i = 0
    while i < args.count {
      let arg = args[i]
      switch arg {
      case "-h", "--help": return .success(.help)
      case "-V", "--version": return .success(.version)
      case "--indexer-status": return .success(.indexer(command: "status"))
      case "--indexer-uninstall": return .success(.indexer(command: "uninstall"))
      case "--snapshot":
        guard i + 1 < args.count else { return .failure(.usage("--snapshot requires a PNG path")) }
        var size = NSSize(width: 1180, height: 760)
        if i + 2 < args.count, let parsed = parseSize(args[i + 2]) { size = parsed }
        return .success(.snapshot(path: args[i + 1], size: size))
      case "--bench": bench = true
      case "--json": json = true
      case "--iterations":
        guard i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else {
          return .failure(.usage("--iterations requires a positive integer"))
        }
        iterations = n
        i += 1
      case "--":
        path = args.dropFirst(i + 1).first
        i = args.count
      default:
        if arg.hasPrefix("-") { return .failure(.usage("unknown option '\(arg)'")) }
        guard path == nil else { return .failure(.usage("unexpected argument '\(arg)'")) }
        path = arg
      }
      i += 1
    }
    if bench { return .success(.bench(iterations: iterations, json: json)) }
    guard let raw = path else { return .success(.browse(path: nil)) }
    let resolved = AppCoordinator.resolve(raw, relativeTo: cwd)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue
    else {
      return .failure(.badPath("not a directory: \(resolved)"))
    }
    return .success(.browse(path: resolved))
  }

  private static func parseSize(_ s: String) -> NSSize? {
    let parts = s.split(separator: "x")
    guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]) else { return nil }
    return NSSize(width: w, height: h)
  }
}

enum LaunchError: Error, Equatable {
  case usage(String)
  case badPath(String)

  var message: String {
    switch self {
    case .usage(let m):
      return "\(LaunchOptions.name): error: \(m)\nTry '\(LaunchOptions.name) --help'."
    case .badPath(let m): return "\(LaunchOptions.name): error: \(m)"
    }
  }
  var exitCode: Int32 {
    switch self {
    case .usage: return 2
    case .badPath: return 1
    }
  }
}
