import XCTest

@testable import Zest

final class UserStateTests: XCTestCase {
  private func tempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("zest-userstate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  func testLoadsPinsFromJson() throws {
    let dir = try tempDir()
    let json = #"[{"name": "Code", "path": "/Users/x/code", "is_default": false}]"#
    try json.write(to: dir.appendingPathComponent("pins.json"), atomically: true, encoding: .utf8)
    let state = UserState(directory: dir)
    XCTAssertEqual(
      state.pins, [UserState.Pin(name: "Code", path: "/Users/x/code", isDefault: false)])
  }

  func testMissingPinsFileYieldsDefaults() throws {
    let state = UserState(directory: try tempDir())
    XCTAssertEqual(state.pins.map(\.name), ["Home", "Desktop", "Documents", "Downloads"])
  }

  func testAddAndRemovePinRoundTripsThroughDisk() throws {
    let dir = try tempDir()
    let state = UserState(directory: dir)
    state.addPin(name: "Proj", path: "/tmp/proj")
    let reloaded = UserState(directory: dir)
    XCTAssertTrue(
      reloaded.pins.contains(UserState.Pin(name: "Proj", path: "/tmp/proj", isDefault: false)))
    reloaded.removePin(path: "/tmp/proj")
    let again = UserState(directory: dir)
    XCTAssertFalse(again.pins.contains(where: { $0.path == "/tmp/proj" }))
  }

  func testLoadsFolderColors() throws {
    let dir = try tempDir()
    let json =
      #"{"version": 1, "folders": {"/a/b": {"red": 214, "green": 180, "blue": 89, "alpha": 255}}}"#
    try json.write(
      to: dir.appendingPathComponent("folder_colors.json"), atomically: true, encoding: .utf8)
    let state = UserState(directory: dir)
    let c = try XCTUnwrap(state.folderColor(forPath: "/a/b"))
    let rgb = try XCTUnwrap(c.usingColorSpace(.sRGB))
    XCTAssertEqual(rgb.redComponent, 214.0 / 255.0, accuracy: 0.001)
    XCTAssertEqual(rgb.greenComponent, 180.0 / 255.0, accuracy: 0.001)
    XCTAssertEqual(rgb.blueComponent, 89.0 / 255.0, accuracy: 0.001)
    XCTAssertEqual(rgb.alphaComponent, 255.0 / 255.0, accuracy: 0.001)
  }

  func testCorruptJsonFallsBackToDefaults() throws {
    let dir = try tempDir()
    try "not json {".write(
      to: dir.appendingPathComponent("pins.json"), atomically: true, encoding: .utf8)
    let state = UserState(directory: dir)
    XCTAssertEqual(state.pins.map(\.name), ["Home", "Desktop", "Documents", "Downloads"])
  }

  // Important-2: empty pins file is a valid zero-pin state, not a signal to resurrect defaults
  func testEmptyPinsArrayPersistsAsZeroPins() throws {
    let dir = try tempDir()
    try "[]".write(
      to: dir.appendingPathComponent("pins.json"), atomically: true, encoding: .utf8)
    let state = UserState(directory: dir)
    XCTAssertTrue(state.pins.isEmpty)
  }

  // Important-1: savePins() must create the directory if it doesn't exist yet
  func testSavePinsCreatesDirectoryIfMissing() throws {
    let base = try tempDir()
    let zestDir = base.appendingPathComponent("zest")
    // zestDir intentionally NOT created — simulate fresh machine
    let state = UserState(directory: zestDir)
    state.addPin(name: "Work", path: "/tmp/work")
    let reloaded = UserState(directory: zestDir)
    XCTAssertTrue(reloaded.pins.contains(where: { $0.path == "/tmp/work" }))
  }

  // Important-3: duplicate path is deduplicated; only one entry should persist
  func testDuplicatePinPathIsDeduped() throws {
    let dir = try tempDir()
    let state = UserState(directory: dir)
    state.addPin(name: "Alpha", path: "/tmp/dup")
    state.addPin(name: "Beta", path: "/tmp/dup")
    let reloaded = UserState(directory: dir)
    let matches = reloaded.pins.filter { $0.path == "/tmp/dup" }
    XCTAssertEqual(matches.count, 1)
  }
}
