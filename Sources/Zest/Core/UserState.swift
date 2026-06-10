import AppKit
import Foundation

/// Pins + folder colors persisted as JSON in the zest app-support directory.
/// Replaces the legacy Zig `user_state.zig` — the Swift app owns UI state.
/// File formats are unchanged so pins.json / folder_colors.json written by
/// the old app keep working. Missing or undecodable files fall back to
/// defaults; saves are atomic. Not thread-safe; main-thread only.
final class UserState {
  struct Pin: Codable, Equatable {
    let name: String
    let path: String
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
      case name, path
      case isDefault = "is_default"
    }
  }

  private struct ColorEntry: Codable {
    let red: Int
    let green: Int
    let blue: Int
    let alpha: Int
  }

  private struct ColorsFile: Codable {
    let version: Int
    let folders: [String: ColorEntry]
  }

  private(set) var pins: [Pin]
  private var colors: [String: NSColor]
  private let pinsURL: URL?
  private let colorsURL: URL?

  /// `directory` is the zest app-support dir; nil (no app support) yields
  /// in-memory defaults that don't persist.
  init(directory: URL?) {
    pinsURL = directory?.appendingPathComponent("pins.json")
    colorsURL = directory?.appendingPathComponent("folder_colors.json")
    pins = Self.loadPins(from: pinsURL) ?? Self.defaultPins()
    colors = Self.loadColors(from: colorsURL)
  }

  func folderColor(forPath path: String) -> NSColor? {
    colors[path]
  }

  func addPin(name: String, path: String) {
    guard !pins.contains(where: { $0.path == path }) else { return }
    pins.append(Pin(name: name, path: path, isDefault: false))
    savePins()
  }

  func removePin(path: String) {
    pins.removeAll { $0.path == path }
    savePins()
  }

  // MARK: - Load / save

  private static func defaultPins() -> [Pin] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    func sub(_ n: String) -> String { (home as NSString).appendingPathComponent(n) }
    return [
      Pin(name: "Home", path: home, isDefault: true),
      Pin(name: "Desktop", path: sub("Desktop"), isDefault: true),
      Pin(name: "Documents", path: sub("Documents"), isDefault: true),
      Pin(name: "Downloads", path: sub("Downloads"), isDefault: true),
    ]
  }

  private static func loadPins(from url: URL?) -> [Pin]? {
    guard let url, let data = try? Data(contentsOf: url) else { return nil }
    guard let parsed = try? JSONDecoder().decode([Pin].self, from: data) else {
      if FileManager.default.fileExists(atPath: url.path) {
        NSLog("UserState: pins.json exists but failed to decode (corrupt?)")
      }
      return nil
    }
    return parsed
  }

  private static func loadColors(from url: URL?) -> [String: NSColor] {
    guard let url, let data = try? Data(contentsOf: url),
      let parsed = try? JSONDecoder().decode(ColorsFile.self, from: data)
    else { return [:] }
    return parsed.folders.mapValues { e in
      NSColor(
        red: CGFloat(e.red) / 255, green: CGFloat(e.green) / 255,
        blue: CGFloat(e.blue) / 255, alpha: CGFloat(e.alpha) / 255)
    }
  }

  private func savePins() {
    guard let pinsURL else { return }
    try? FileManager.default.createDirectory(
      at: pinsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(pins) else {
      NSLog("UserState: failed to encode pins")
      return
    }
    do {
      try data.write(to: pinsURL, options: .atomic)
    } catch {
      NSLog("UserState: failed to save pins: \(error)")
    }
  }
}
