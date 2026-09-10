import AppKit
import SwiftUI

/// There is no public API to request or reliably query Full Disk Access.
/// Preparation never starts a scan; only Done or Skip finishes setup.
enum IndexerAccessSetup {
  case install, existing

  var preparationCommands: [[String]] {
    self == .install ? [["prepare-install"]] : [["stop"], ["prepare-install"]]
  }

  func completionArguments(helper: URL) -> [String] {
    self == .install ? ["install", "--binary-path", helper.path] : ["start"]
  }
}

final class IndexerAccessSetupController: NSWindowController, NSWindowDelegate {
  private let helper: URL
  private let onStart: () -> Void
  let model = IndexerOnboardingModel()
  private let verify: () throws -> IndexerAccessStatus
  private let queue = DispatchQueue(label: "dev.zest.access-check", qos: .utility)
  private var timer: Timer?
  private var checking = false
  private var active = false

  init(
    helper: URL, verify: (() throws -> IndexerAccessStatus)? = nil, onStart: @escaping () -> Void
  ) {
    self.helper = helper
    self.onStart = onStart
    self.verify = verify ?? { try IndexerAccessVerifier.check(helper: helper) }
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 650),
      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "Set up Zest"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = NSColor(red: 27 / 255, green: 31 / 255, blue: 35 / 255, alpha: 1)
    super.init(window: window)
    window.delegate = self
    let hosting = NSHostingView(
      rootView: IndexerOnboardingView(
        model: model, helper: helper,
        onNext: { [weak self] in self?.nextStep() },
        onSkip: { [weak self] in self?.confirmSkip() },
        onSettings: { [weak self] in self?.openSettings(nil) },
        onReveal: { [weak self] in self?.revealHelper(nil) },
        onCopy: { [weak self] in self?.copyHelperPath() }))
    // The window owns its geometry, not NSHostingView's title-bar-adjusted minimum size.
    hosting.sizingOptions = []
    window.contentView = hosting
    // fullSizeContentView includes the title bar; contentRect at initialization
    // otherwise adds another 28 points beyond the designed hosting surface.
    window.setFrame(
      NSRect(origin: window.frame.origin, size: NSSize(width: 860, height: 650)), display: false)
    window.center()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func showWindow(_ sender: Any?) {
    guard !model.completed else { return }
    super.showWindow(sender)
    guard !active, !model.completed else { return }
    active = true
    pollAccess()
    let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.pollAccess() }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func pollAccess() {
    guard active, !checking else { return }
    checking = true
    let verify = self.verify
    queue.async { [weak self] in
      let status = (try? verify()) ?? .unavailable
      DispatchQueue.main.async {
        guard let self else { return }
        self.checking = false
        guard self.active else { return }
        self.updateAccessStatus(status)
      }
    }
  }

  func updateAccessStatus(_ status: IndexerAccessStatus) {
    guard !model.completed, model.status != status else { return }
    model.status = status
  }

  func nextStep() {
    guard !model.completed else { return }
    switch model.step {
    case .welcome: model.step = .access
    case .access:
      if model.settingsOpened || model.status == .verified {
        model.step = .verify
      } else {
        openSettings(nil)
      }
    case .verify: startIndexing(nil)
    }
  }

  private func copyHelperPath() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(helper.path, forType: .string)
    model.pathCopied = true
  }

  private func confirmSkip() {
    guard let window, !model.completed else { return }
    let alert = NSAlert()
    alert.messageText = "Start without verifying access?"
    alert.informativeText =
      "macOS may ask for individual folder permissions, and some files may be missing from your index. You can finish access setup later from the Index menu."
    alert.addButton(withTitle: "Start Without Verification")
    alert.addButton(withTitle: "Keep Setting Up")
    alert.beginSheetModal(for: window) { [weak self] response in
      if response == .alertFirstButtonReturn { self?.skipSetup(nil) }
    }
  }

  private func stopPolling() {
    active = false
    timer?.invalidate()
    timer = nil
  }

  func windowWillClose(_ notification: Notification) {
    model.completed = true
    stopPolling()
  }

  @objc private func revealHelper(_: Any?) {
    NSWorkspace.shared.activateFileViewerSelecting([helper])
  }

  @objc private func openSettings(_: Any?) {
    let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    // A failed deep link must still allow continuing after opening Settings manually.
    model.settingsOpened = true
    model.settingsError = !NSWorkspace.shared.open(url)
  }

  @objc func startIndexing(_: Any?) {
    guard model.canFinish else { return }
    finishSetup()
  }

  @objc func skipSetup(_: Any?) { finishSetup() }

  private func finishSetup() {
    guard !model.completed else { return }
    model.completed = true
    stopPolling()
    close()
    onStart()
  }

  @objc func cancelSetup(_: Any?) {
    model.completed = true
    stopPolling()
    close()
  }
}
