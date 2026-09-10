import Foundation

enum IndexerAccessStatus: String {
  case verified, denied, unavailable
}

enum IndexerAccessVerifier {
  /// Launch the exact installed executable through launchd, so permission from
  /// Zest, Terminal, or the test runner cannot make the check falsely succeed.
  /// A fresh process also avoids cached permission decisions between checks.
  static func check(helper: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws
    -> IndexerAccessStatus
  {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory.appendingPathComponent("zest-access-\(UUID().uuidString)")
    try fm.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: directory) }
    let label = "dev.zest.access.\(UUID().uuidString)"
    let domain = "gui/\(getuid())"
    let target = "\(domain)/\(label)"
    let output = directory.appendingPathComponent("result")
    let plist = directory.appendingPathComponent("probe.plist")
    let contents: [String: Any] = [
      "Label": label,
      "ProgramArguments": [helper.path, "probe-access"],
      "EnvironmentVariables": ["HOME": home.path],
      "RunAtLoad": true,
      "KeepAlive": false,
      "ProcessType": "Background",
      "StandardOutPath": output.path,
      "StandardErrorPath": directory.appendingPathComponent("error").path,
    ]
    try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0).write(
      to: plist)
    let launchctl = URL(fileURLWithPath: "/bin/launchctl")
    // Cleanup is attempted even if bootstrap partially succeeded before error.
    defer {
      _ = try? IndexerMenuController.run(launchctl, arguments: ["bootout", target], timeout: 5)
    }
    _ = try IndexerMenuController.run(
      launchctl, arguments: ["bootstrap", domain, plist.path], timeout: 5)
    let deadline = ProcessInfo.processInfo.systemUptime + 4
    while ProcessInfo.processInfo.systemUptime < deadline {
      if let data = try? Data(contentsOf: output), data.last == 10 {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(
          in: .whitespacesAndNewlines)
        return IndexerAccessStatus(rawValue: text) ?? .unavailable
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return .unavailable
  }
}
