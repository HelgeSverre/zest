import AppKit
import ServiceManagement

enum IndexerState: String {
  case notInstalled = "not_installed"
  case stopped, running, waiting, requiresApproval, failed

  var title: String {
    switch self {
    case .notInstalled: return "Indexer: Not Installed"
    case .stopped: return "Indexer: Stopped"
    case .running: return "Indexer: Running"
    case .waiting: return "Indexer: Waiting to Start"
    case .requiresApproval: return "Indexer: Background Permission Required"
    case .failed: return "Indexer: Failed to Start"
    }
  }

  var actions: [IndexerAction] {
    switch self {
    case .notInstalled: return [.install]
    case .stopped: return [.start, .permissions, .uninstall]
    case .running: return [.reindex, .stop, .restart, .permissions, .uninstall]
    case .waiting: return [.stop, .restart, .permissions, .uninstall]
    case .requiresApproval: return [.approveBackground, .uninstall]
    case .failed: return [.restart, .permissions, .uninstall]
    }
  }
}

enum IndexerAction: String {
  case install, start, stop, restart, reindex, permissions, uninstall, approveBackground
  var title: String {
    switch self {
    case .install: return "Set Up Indexer…"
    case .start: return "Start Indexer"
    case .stop: return ReleaseInstallation.isPackaged ? "Stop Indexer" : "Pause Until Next Login"
    case .restart: return "Restart Indexer"
    case .reindex: return "Re-index Now"
    case .permissions: return "Set Up Full Disk Access…"
    case .uninstall: return "Disable Background Indexing…"
    case .approveBackground: return "Allow Background Indexing in Settings…"
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
  private var statusError: String?
  private var accessSetup: IndexerAccessSetupController?
  private let bundledService: BundledIndexerService?

  init(helper: URL? = nil) {
    self.helper = helper
    if helper == nil, ReleaseInstallation.isPackaged,
      let bundled = ReleaseInstallation.bundledHelper(in: Bundle.main.bundleURL)
    {
      self.helper = bundled
      bundledService = BundledIndexerService(helper: bundled)
    } else {
      bundledService = nil
    }
    super.init()
    menu.autoenablesItems = false
    menu.delegate = self
    render()
  }

  func menuWillOpen(_: NSMenu) { refresh() }

  /// First launch only reads state. macOS owns the bundled helper's lifetime;
  /// never register or migrate a developer daemon without explicit setup.
  func refreshOnLaunch() {
    guard ReleaseInstallation.isPackaged,
      ReleaseInstallation.isInstalled(Bundle.main.bundleURL),
      let helper = Self.findHelper()
    else { return }
    self.helper = helper
    refresh()
  }

  func setUpAccess() { resolveProgressAction(setup: true) }
  func retryIndexing() { resolveProgressAction(setup: false) }

  private func resolveProgressAction(setup: Bool) {
    guard !busy else { return }
    guard ReleaseInstallation.requireInstalledApp() else { return }
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
      if state == .requiresApproval {
        SMAppService.openSystemSettingsLoginItems()
        return
      }
      if setup || state == .notInstalled {
        self.beginAccessSetup(state == .notInstalled ? .install : .existing, helper: helper)
      } else {
        let command =
          state == .running
          ? "reindex" : (state == .waiting || state == .failed) ? "restart" : "start"
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
    status.toolTip = statusError
    menu.addItem(.separator())
    for action in state?.actions ?? [] {
      let item = NSMenuItem(
        title: action.title, action: #selector(performAction(_:)), keyEquivalent: "")
      item.representedObject = action.rawValue
      item.target = self
      item.isEnabled = !busy && helper != nil && accessSetup?.window?.isVisible != true
      menu.addItem(item)
    }
    if helper == nil && !busy && !ReleaseInstallation.isPackaged {
      let locate = NSMenuItem(
        title: "Locate Indexer…", action: #selector(locateIndexer(_:)), keyEquivalent: "")
      locate.target = self
      menu.addItem(locate)
    }
    if message != nil && helper != nil && !busy {
      if statusError != nil {
        let details = NSMenuItem(
          title: "Show Status Error…", action: #selector(showStatusError(_:)), keyEquivalent: "")
        details.target = self
        menu.addItem(details)
      }
      let refresh = NSMenuItem(
        title: "Refresh Status", action: #selector(refreshStatus(_:)), keyEquivalent: "")
      refresh.target = self
      menu.addItem(refresh)
    }
  }

  @objc private func refreshStatus(_: Any?) { refresh() }

  @objc private func showStatusError(_: Any?) {
    guard let statusError else { return }
    let alert = NSAlert()
    alert.messageText = "Couldn't check indexer status"
    alert.informativeText = statusError
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  private func refresh() {
    guard !busy else { return }
    statusError = nil
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
    let control = control(for: helper)
    queue.async { [weak self] in
      let result = Result { try control.state() }
      DispatchQueue.main.async {
        guard let self, self.generation == requestGeneration else { return }
        self.busy = false
        switch result {
        case .success(let state):
          self.state = state
          self.message = nil
        case .failure(let error):
          self.state = nil
          self.message = "Indexer: Status Unavailable"
          self.statusError = error.localizedDescription
        }
        self.render()
      }
    }
  }

  @objc private func performAction(_ item: NSMenuItem) {
    guard !busy, let helper,
      let raw = item.representedObject as? String, let action = IndexerAction(rawValue: raw)
    else { return }
    guard ReleaseInstallation.requireInstalledApp() else { return }
    if action == .approveBackground {
      SMAppService.openSystemSettingsLoginItems()
      return
    }
    if action == .uninstall {
      let alert = NSAlert()
      alert.messageText = "Disable background indexing?"
      alert.informativeText =
        "This stops the indexer and removes its background registration, including at future logins. Your index, pins, and preferences are kept. You can enable indexing again from the Index menu."
      alert.addButton(withTitle: "Cancel")
      alert.addButton(withTitle: "Disable Indexing")
      guard alert.runModal() == .alertSecondButtonReturn else { return }
    }
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
        self.bundledService != nil
        ? helper
        : setup == .install
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
    let control = control(for: helper)
    queue.async { [weak self] in
      let result = Result {
        var output = ""
        for arguments in commands {
          output = try control.execute(arguments)
        }
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
        if case .success(let output) = result {
          onSuccess?(output)
          if self.bundledService?.requiresApproval == true,
            commands.contains(where: { ["install", "start", "restart"].contains($0.first ?? "") })
          {
            let alert = NSAlert()
            alert.messageText = "Allow Zest to run in the background"
            alert.informativeText =
              "macOS needs your approval in Login Items before indexing can start. Full Disk Access and background permission are separate settings."
            alert.addButton(withTitle: "Open Login Items")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
              SMAppService.openSystemSettingsLoginItems()
            }
          }
        }
        self.refresh()
      }
    }
  }

  @objc private func locateIndexer(_: Any?) {
    guard !ReleaseInstallation.isPackaged else {
      let alert = NSAlert()
      alert.messageText = "Zest’s bundled indexer is missing"
      alert.informativeText =
        "Reinstall Zest from its signed installer. Packaged apps cannot use an external or development indexer."
      alert.runModal()
      return
    }
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

  private func control(for helper: URL) -> IndexerControl {
    if let bundledService { return bundledService }
    return CommandLineIndexerService(helper: helper)
  }

  static func findHelper() -> URL? {
    if ReleaseInstallation.isPackaged {
      return ReleaseInstallation.bundledHelper(in: Bundle.main.bundleURL)
    }
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

}
