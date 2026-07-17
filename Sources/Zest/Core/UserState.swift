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

  struct SavedFilter: Codable, Equatable {
    let name: String
    let query: String
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

  /// Small scalar view preferences (prefs.json). Additive: unknown keys are
  /// dropped on decode, absent keys take their defaults.
  private struct Prefs: Codable {
    var foldersOnTop: Bool = false
  }

  private(set) var pins: [Pin]
  private(set) var colors: [String: NSColor]
  private(set) var filters: [SavedFilter]
  private var prefs: Prefs
  private let pinsURL: URL?
  private let colorsURL: URL?
  private let filtersURL: URL?
  private let prefsURL: URL?

  /// `directory` is the zest app-support dir; nil (no app support) yields
  /// in-memory defaults that don't persist.
  init(directory: URL?) {
    pinsURL = directory?.appendingPathComponent("pins.json")
    colorsURL = directory?.appendingPathComponent("folder_colors.json")
    filtersURL = directory?.appendingPathComponent("filters.json")
    prefsURL = directory?.appendingPathComponent("prefs.json")
    pins = Self.loadPins(from: pinsURL) ?? Self.defaultPins()
    colors = Self.loadColors(from: colorsURL)
    filters = Self.loadFilters(from: filtersURL)
    prefs = Self.loadPrefs(from: prefsURL)
  }

  // MARK: - View preferences

  var foldersOnTop: Bool { prefs.foldersOnTop }

  func setFoldersOnTop(_ value: Bool) {
    prefs.foldersOnTop = value
    savePrefs()
  }

  func folderColor(forPath path: String) -> NSColor? {
    colors[path]
  }

  func setFolderColor(forPath path: String, color: NSColor?) {
    if let color {
      colors[path] = color
    } else {
      colors.removeValue(forKey: path)
    }
    saveColors()
  }

  func isPinned(path: String) -> Bool {
    pins.contains { $0.path == path }
  }

  func addPin(name: String, path: String) {
    guard !isPinned(path: path) else { return }
    pins.append(Pin(name: name, path: path, isDefault: false))
    savePins()
  }

  func removePin(path: String) {
    pins.removeAll { $0.path == path }
    savePins()
  }

  // MARK: - Saved filters

  func addFilter(name: String, query: String) {
    filters.append(SavedFilter(name: name, query: query))
    saveFilters()
  }

  func removeFilter(at index: Int) {
    guard filters.indices.contains(index) else { return }
    filters.remove(at: index)
    saveFilters()
  }

  func updateFilter(at index: Int, name: String, query: String) {
    guard filters.indices.contains(index) else { return }
    filters[index] = SavedFilter(name: name, query: query)
    saveFilters()
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

  private static func loadFilters(from url: URL?) -> [SavedFilter] {
    guard let url, let data = try? Data(contentsOf: url) else { return [] }
    guard let parsed = try? JSONDecoder().decode([SavedFilter].self, from: data) else {
      if FileManager.default.fileExists(atPath: url.path) {
        NSLog("UserState: filters.json exists but failed to decode (corrupt?)")
      }
      return []
    }
    return parsed
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

  private func saveColors() {
    guard let colorsURL else { return }
    try? FileManager.default.createDirectory(
      at: colorsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    var entries: [String: ColorEntry] = [:]
    for (path, color) in colors {
      guard let rgb = color.usingColorSpace(.extendedSRGB) else { continue }
      entries[path] = ColorEntry(
        red: Int(round(rgb.redComponent * 255)),
        green: Int(round(rgb.greenComponent * 255)),
        blue: Int(round(rgb.blueComponent * 255)),
        alpha: Int(round(rgb.alphaComponent * 255)))
    }
    let file = ColorsFile(version: 1, folders: entries)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(file) else {
      NSLog("UserState: failed to encode folder colors")
      return
    }
    do {
      try data.write(to: colorsURL, options: .atomic)
    } catch {
      NSLog("UserState: failed to save folder colors: \(error)")
    }
  }

  private static func loadPrefs(from url: URL?) -> Prefs {
    guard let url, let data = try? Data(contentsOf: url),
      let parsed = try? JSONDecoder().decode(Prefs.self, from: data)
    else { return Prefs() }
    return parsed
  }

  private func savePrefs() {
    guard let prefsURL else { return }
    try? FileManager.default.createDirectory(
      at: prefsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(prefs) else {
      NSLog("UserState: failed to encode prefs")
      return
    }
    do {
      try data.write(to: prefsURL, options: .atomic)
    } catch {
      NSLog("UserState: failed to save prefs: \(error)")
    }
  }

  private func saveFilters() {
    guard let filtersURL else { return }
    try? FileManager.default.createDirectory(
      at: filtersURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(filters) else {
      NSLog("UserState: failed to encode filters")
      return
    }
    do {
      try data.write(to: filtersURL, options: .atomic)
    } catch {
      NSLog("UserState: failed to save filters: \(error)")
    }
  }
}
