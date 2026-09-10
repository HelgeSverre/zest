import AppKit
import ServiceManagement

protocol BackgroundServiceRegistration {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() throws
}
extension SMAppService: BackgroundServiceRegistration {}

/// All mutations run on the menu's serial queue. Registration is exclusively
/// owned by SMAppService; the CLI's launchctl installer remains development-only.
final class BundledIndexerService: IndexerControl {
  static let label = "dev.zest.app.indexer"
  private let service: BackgroundServiceRegistration
  private let helper: URL
  private let defaults: UserDefaults
  private let run: (URL, [String]) throws -> String
  var requiresApproval: Bool { service.status == .requiresApproval }

  init(
    helper: URL, defaults: UserDefaults = .standard,
    registration: BackgroundServiceRegistration = SMAppService.agent(
      plistName: "dev.zest.app.indexer.plist"),
    run: @escaping (URL, [String]) throws -> String = {
      try IndexerProcess.run($0, arguments: $1)
    }
  ) {
    self.helper = helper
    self.service = registration
    self.defaults = defaults
    self.run = run
  }

  static func state(
    authorization: SMAppService.Status, previouslySetUp: Bool,
    running: Bool
  ) throws -> IndexerState {
    switch authorization {
    case .enabled: return running ? .running : .waiting
    case .requiresApproval: return .requiresApproval
    case .notRegistered: return previouslySetUp ? .stopped : .notInstalled
    case .notFound: throw failure("The bundled indexer registration is missing. Reinstall Zest.")
    @unknown default: throw failure("macOS returned an unknown background-item status.")
    }
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "ZestIndexer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  func state() throws -> IndexerState {
    let authorization = service.status
    let running: Bool
    if authorization == .enabled {
      // A registered job may still be launching; don't confuse eligibility with liveness.
      do {
        let output = try run(
          URL(fileURLWithPath: "/bin/launchctl"),
          ["print", "gui/\(getuid())/\(Self.label)"])
        running = output.contains("state = running")
      } catch {
        guard error.localizedDescription.contains("Could not find service") else { throw error }
        running = false
      }
    } else {
      running = false
    }
    return try Self.state(
      authorization: authorization,
      previouslySetUp: defaults.bool(forKey: "indexerSetupCompleted"), running: running)
  }

  func execute(_ arguments: [String]) throws -> String {
    guard let command = arguments.first else { throw Self.failure("Missing indexer command.") }
    switch command {
    case "status": return try state().rawValue
    case "prepare-install":
      // Explicit setup migrates the old developer installation. Never run this
      // automatically on first launch or from the installer package.
      try stop()
      let legacy = try run(helper, ["status"]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard let legacyState = IndexerState(rawValue: legacy) else {
        throw Self.failure("Could not determine the previous indexer's state.")
      }
      if legacyState != .notInstalled { _ = try run(helper, ["uninstall"]) }
      return helper.path
    case "install", "start":
      if service.status == .requiresApproval { return "" }
      if service.status != .enabled { try service.register() }
      defaults.set(true, forKey: "indexerSetupCompleted")
    case "stop", "uninstall": try stop()
    case "restart":
      try stop()
      try service.register()
      defaults.set(true, forKey: "indexerSetupCompleted")
    case "reindex":
      guard try state() == .running else {
        throw Self.failure("The indexer is not running. Start it first.")
      }
      let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/zest", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try Data(UUID().uuidString.utf8).write(
        to: directory.appendingPathComponent("reindex.request"), options: .atomic)
    default: throw Self.failure("Unsupported bundled indexer command: \(command)")
    }
    return ""
  }

  private func stop() throws {
    if service.status == .notRegistered { return }
    try service.unregister()
    // unregister can finish before launchd has reaped the job. Never race a
    // following register against an old process still holding the same label.
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
      do {
        _ = try run(
          URL(fileURLWithPath: "/bin/launchctl"), ["print", "gui/\(getuid())/\(Self.label)"])
      } catch {
        // Only confirmed absence permits the next registration.
        if error.localizedDescription.contains("Could not find service") { return }
        throw error
      }
      Thread.sleep(forTimeInterval: 0.25)
    }
    throw Self.failure("macOS has not finished stopping the indexer. Try again shortly.")
  }
}
