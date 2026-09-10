import AppKit

enum IndexerState: String {
  case notInstalled = "not_installed"
  case stopped, running, waiting

  var title: String {
    switch self {
    case .notInstalled: return "Indexer: Not Installed"
    case .stopped: return "Indexer: Stopped"
    case .running: return "Indexer: Running"
    case .waiting: return "Indexer: Waiting to Start"
    }
  }

  var actions: [IndexerAction] {
    switch self {
    case .notInstalled: return [.install]
    case .stopped: return [.start, .permissions]
    case .running: return [.reindex, .stop, .restart, .permissions]
    case .waiting: return [.stop, .restart, .permissions]
    }
  }
}

enum IndexerAction: String {
  case install, start, stop, restart, reindex, permissions
  var title: String {
    switch self {
    case .install: return "Set Up Indexer…"
    case .start: return "Start Indexer"
    case .stop: return "Stop Indexer"
    case .restart: return "Restart Indexer"
    case .reindex: return "Re-index Now"
    case .permissions: return "Set Up Full Disk Access…"
    }
  }
}

/// All process work is serialized off-main. Menu state is refreshed when opened
/// and after every action; failures remain visible and actions report details.
final class IndexerMenuController: NSObject, NSMenuDelegate {
  let menu = NSMenu(title: "Index")
  private let queue = DispatchQueue(label: "dev.zest.indexer-control", qos: .utility)
  private var helper: URL?
  private var state: IndexerState?
  private var busy = false
  private var generation = 0
  private var message: String?
  private var accessSetup: IndexerAccessSetupController?

  init(helper: URL? = nil) {
    self.helper = helper
    super.init()
    menu.autoenablesItems = false
    menu.delegate = self
    render()
  }

  func menuWillOpen(_: NSMenu) { refresh() }

  func setUpAccess() { resolveProgressAction(setup: true) }
  func retryIndexing() { resolveProgressAction(setup: false) }

  private func resolveProgressAction(setup: Bool) {
    guard !busy else { return }
    helper = helper ?? Self.findHelper()
    guard let helper else {
      locateIndexer(nil)
      return
    }
    if let accessSetup, accessSetup.window?.isVisible == true {
      accessSetup.showWindow(nil)
      NSApp.activate(ignoringOtherApps: true)
      return
    }
    execute(helper: helper, arguments: ["status"], title: "Check Indexer") { [weak self] output in
      guard let self,
        let state = IndexerState(rawValue: output.trimmingCharacters(in: .whitespacesAndNewlines))
      else { return }
      if setup || state == .notInstalled {
        self.beginAccessSetup(state == .notInstalled ? .install : .existing, helper: helper)
      } else {
        let command = state == .running ? "reindex" : state == .waiting ? "restart" : "start"
        self.execute(helper: helper, arguments: [command], title: "Retry Indexing")
      }
    }
  }

  private func render() {
    menu.removeAllItems()
    let status = NSMenuItem(
      title: busy ? "Indexer: Checking…" : (message ?? state?.title ?? "Indexer: Checking…"),
      action: nil, keyEquivalent: "")
    status.isEnabled = false
    menu.addItem(status)
    menu.addItem(.separator())
    for action in state?.actions ?? [] {
      let item = NSMenuItem(
        title: action.title, action: #selector(performAction(_:)), keyEquivalent: "")
      item.representedObject = action.rawValue
      item.target = self
      item.isEnabled = !busy && helper != nil && accessSetup?.window?.isVisible != true
      menu.addItem(item)
    }
    if helper == nil && !busy {
      let locate = NSMenuItem(
        title: "Locate Indexer…", action: #selector(locateIndexer(_:)), keyEquivalent: "")
      locate.target = self
      menu.addItem(locate)
    }
    if message != nil && helper != nil && !busy {
      let refresh = NSMenuItem(
        title: "Refresh Status", action: #selector(refreshStatus(_:)), keyEquivalent: "")
      refresh.target = self
      menu.addItem(refresh)
    }
  }

  @objc private func refreshStatus(_: Any?) { refresh() }

  private func refresh() {
    guard !busy else { return }
    helper = helper ?? Self.findHelper()
    guard let helper else {
      message = "Indexer Tool Not Found"
      state = nil
      render()
      return
    }
    busy = true
    generation += 1
    let requestGeneration = generation
    render()
    queue.async { [weak self] in
      let result = Result { try Self.readState(helper: helper) }
      DispatchQueue.main.async {
        guard let self, self.generation == requestGeneration else { return }
        self.busy = false
        switch result {
        case .success(let state):
          self.state = state
          self.message = nil
        case .failure:
          self.state = nil
          self.message = "Indexer: Status Unavailable"
        }
        self.render()
      }
    }
  }

  @objc private func performAction(_ item: NSMenuItem) {
    guard !busy, let helper,
      let raw = item.representedObject as? String, let action = IndexerAction(rawValue: raw)
    else { return }
    if action == .install || action == .permissions {
      beginAccessSetup(action == .install ? .install : .existing, helper: helper)
      return
    }
    execute(helper: helper, arguments: [action.rawValue], title: action.title)
  }

  private func beginAccessSetup(_ setup: IndexerAccessSetup, helper: URL) {
    if let accessSetup, accessSetup.window?.isVisible == true {
      accessSetup.showWindow(nil)
      return
    }
    execute(helper: helper, commands: setup.preparationCommands, title: "Prepare Indexer Access") {
      [weak self] output in
      guard let self else { return }
      let installed =
        setup == .install
        ? URL(fileURLWithPath: output.trimmingCharacters(in: .whitespacesAndNewlines))
        : Self.installedHelperURL
      self.accessSetup = IndexerAccessSetupController(helper: installed) { [weak self] in
        self?.execute(
          helper: helper, arguments: setup.completionArguments(helper: installed),
          title: "Start Indexing")
      }
      self.accessSetup?.showWindow(nil)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  private func execute(
    helper: URL, arguments: [String], title: String, onSuccess: ((String) -> Void)? = nil
  ) {
    execute(helper: helper, commands: [arguments], title: title, onSuccess: onSuccess)
  }

  private func execute(
    helper: URL, commands: [[String]], title: String, onSuccess: ((String) -> Void)? = nil
  ) {
    // A setup-window action may arrive while a status refresh is in flight.
    // Queue it rather than dropping the user's Start, and discard that stale
    // refresh's delivery. The serial queue keeps process operations ordered.
    busy = true
    generation += 1
    let requestGeneration = generation
    render()
    queue.async { [weak self] in
      let result = Result {
        var output = ""
        for arguments in commands { output = try Self.run(helper, arguments: arguments) }
        return output
      }
      DispatchQueue.main.async {
        guard let self, self.generation == requestGeneration else { return }
        self.busy = false
        if case .failure(let error) = result {
          let alert = NSAlert()
          alert.messageText = "Couldn’t \(title.lowercased())"
          alert.informativeText = error.localizedDescription
          alert.alertStyle = .warning
          alert.runModal()
        }
        if case .success(let output) = result { onSuccess?(output) }
        self.refresh()
      }
    }
  }

  @objc private func locateIndexer(_: Any?) {
    let panel = NSOpenPanel()
    panel.title = "Locate zest-indexer"
    panel.message = "Choose the zest-indexer executable to manage background indexing."
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url,
      FileManager.default.isExecutableFile(atPath: url.path)
    else { return }
    helper = url
    refresh()
  }

  static func readState(helper: URL) throws -> IndexerState {
    let output = try run(helper, arguments: ["status"]).trimmingCharacters(
      in: .whitespacesAndNewlines)
    guard let state = IndexerState(rawValue: output) else {
      throw NSError(
        domain: "ZestIndexer", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            "The indexer returned an unrecognized status. Rebuild or update zest-indexer."
        ])
    }
    return state
  }

  static func findHelper() -> URL? {
    var candidates: [URL] = []
    if let resources = Bundle.main.resourceURL {
      candidates.append(resources.appendingPathComponent("zest-indexer"))
    }
    // SwiftPM places Zest several levels below the checkout. This also works
    // when launched outside the checkout's current working directory.
    if var directory = Bundle.main.executableURL?.deletingLastPathComponent() {
      for _ in 0..<8 {
        candidates.append(directory.appendingPathComponent("zig-out/bin/zest-indexer"))
        directory.deleteLastPathComponent()
      }
    }
    candidates.append(installedHelperURL)
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  static var installedHelperURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/zest/bin/zest-indexer")
  }

  /// Draining output before waiting prevents a full pipe from deadlocking the
  /// child. A timeout keeps an unresponsive launchctl from wedging controls.
  static func run(_ executable: URL, arguments: [String], timeout timeoutSeconds: TimeInterval = 90)
    throws -> String
  {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + timeoutSeconds, execute: timeout)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    timeout.cancel()
    let output = String(decoding: data, as: UTF8.self)
    guard process.terminationReason == .exit && process.terminationStatus == 0 else {
      throw NSError(
        domain: "ZestIndexer", code: Int(process.terminationStatus),
        userInfo: [
          NSLocalizedDescriptionKey: output.isEmpty
            ? "Indexer command failed or timed out." : output
        ])
    }
    return output
  }
}
