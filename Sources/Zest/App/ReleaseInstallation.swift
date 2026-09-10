import AppKit

/// Release builds never search a checkout or launch an arbitrary located helper.
enum ReleaseInstallation {
  static var isPackaged: Bool { Bundle.main.bundleURL.pathExtension == "app" }

  static func bundledHelper(in bundle: URL) -> URL? {
    let helper = bundle.appendingPathComponent("Contents/Helpers/zest-indexer")
    return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
  }

  static func isInstalled(
    _ bundle: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Bool {
    let parent = bundle.resolvingSymlinksInPath().deletingLastPathComponent().standardizedFileURL
    return parent == URL(fileURLWithPath: "/Applications", isDirectory: true)
      || parent
        == home.appendingPathComponent("Applications", isDirectory: true).standardizedFileURL
  }

  /// Don't register services or stage permission targets from a DMG/translocated copy.
  static func requireInstalledApp() -> Bool {
    guard isPackaged, !isInstalled(Bundle.main.bundleURL) else { return true }
    let alert = NSAlert()
    alert.messageText = "Move Zest to Applications first"
    alert.informativeText =
      "Quit Zest, drag Zest.app into Applications, then open it there to set up background indexing. This keeps updates and permissions tied to your installed copy."
    alert.addButton(withTitle: "Open Applications")
    alert.addButton(withTitle: "Cancel")
    if alert.runModal() == .alertFirstButtonReturn {
      NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }
    return false
  }
}
