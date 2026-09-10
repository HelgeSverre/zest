import AppKit
import SwiftUI
import XCTest

@testable import Zest

final class IndexProgressTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000)

  private func snapshot(
    _ phase: String, updated: Double = 1_000, count: UInt64 = 187_432,
    written: UInt64 = 64, total: UInt64 = 100
  ) -> IndexProgressSnapshot {
    IndexProgressSnapshot(
      version: 1, runId: "fixture", pid: getpid(), startedAt: 900,
      updatedAt: updated, elapsedMs: 72_000, phase: phase, count: count,
      currentPath: "/Users/example/Documents/Projects", written: written, total: total,
      message: phase == "failed" ? "ScanIncomplete" : "")
  }

  func testFirstIndexWaitsForReaderAndQueryNotWriter() {
    let model = IndexProgressModel(hasIndex: false)
    XCTAssertTrue(model.showsOverlay)
    model.update(snapshot("scanning"), usableIndex: false, now: now, alive: { _ in true })
    XCTAssertEqual(model.phase, .scanning)
    XCTAssertNil(model.fraction)
    model.update(snapshot("building"), usableIndex: false, now: now, alive: { _ in true })
    XCTAssertNil(model.fraction)
    model.update(
      snapshot("writing", written: 100), usableIndex: false, now: now, alive: { _ in true })
    XCTAssertEqual(model.fraction, 1)
    XCTAssertTrue(model.showsOverlay)
    XCTAssertEqual(model.phase, .writing)
    model.update(snapshot("published"), usableIndex: false, now: now, alive: { _ in false })
    XCTAssertEqual(model.phase, .loading)
    XCTAssertTrue(model.showsOverlay)
    model.update(nil, usableIndex: true, now: now, alive: { _ in false })
    XCTAssertEqual(model.phase, .ready)
    XCTAssertTrue(model.showsOverlay)
    model.update(nil, usableIndex: true, now: now.addingTimeInterval(2), alive: { _ in false })
    XCTAssertFalse(model.showsOverlay)
  }

  func testRebuildsNeverCoverAnExistingIndexAndBackgroundCanBeReopened() {
    let existing = IndexProgressModel(hasIndex: true)
    existing.update(snapshot("scanning"), usableIndex: true, now: now, alive: { _ in true })
    XCTAssertFalse(existing.showsOverlay)
    XCTAssertTrue(existing.statusText?.contains("Updating index") == true)
    existing.update(snapshot("failed"), usableIndex: true, now: now, alive: { _ in true })
    XCTAssertFalse(existing.showsOverlay)
    let first = IndexProgressModel(hasIndex: false)
    first.dismissed = true
    first.update(snapshot("scanning"), usableIndex: false, now: now, alive: { _ in true })
    XCTAssertFalse(first.showsOverlay)
    first.dismissed = false
    XCTAssertTrue(first.showsOverlay)
  }

  func testOldFailuresCannotOverrideANewerIndexAndReadyCountComesFromReader() {
    let model = IndexProgressModel(hasIndex: true)
    model.update(
      snapshot("failed", updated: 950), usableIndex: true, now: now,
      indexCount: 123, indexModified: 990, alive: { _ in false })
    XCTAssertEqual(model.phase, .ready)
    XCTAssertEqual(model.count, 123)
    XCTAssertNil(model.statusText)
  }

  func testDeadOrStaleProcessAndPublicationFailureNeverPretendToComplete() {
    for (record, alive) in [
      (snapshot("scanning"), false), (snapshot("building", updated: 950), true),
      (snapshot("failed"), true), (snapshot("published", updated: 950), false),
    ] {
      let model = IndexProgressModel(hasIndex: false)
      model.update(record, usableIndex: false, now: now, alive: { _ in alive })
      XCTAssertEqual(model.phase, .interrupted)
      XCTAssertTrue(model.showsOverlay)
      XCTAssertFalse(model.detail.isEmpty)
    }
    let model = IndexProgressModel(hasIndex: false)
    model.update(snapshot("scanning"), usableIndex: false, now: now, alive: { _ in true })
    model.update(nil, usableIndex: false, now: now.addingTimeInterval(13), alive: { _ in true })
    XCTAssertEqual(model.phase, .interrupted)
    model.update(
      snapshot("scanning", updated: 1013), usableIndex: false, now: now.addingTimeInterval(13),
      alive: { _ in true })
    XCTAssertEqual(model.phase, .scanning)
  }

  func testReaderRejectsMalformedOversizedAndInvalidSnapshotsAndPrefersLiveWork() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "zest-progress-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data("{broken".utf8).write(to: directory.appendingPathComponent("progress-broken.json"))
    try Data(repeating: 65, count: 33_000).write(
      to: directory.appendingPathComponent("progress-big.json"))
    try JSONEncoder().encode(snapshot("unknown")).write(
      to: directory.appendingPathComponent("progress-invalid.json"))
    XCTAssertNil(IndexProgressMonitor.read(directory: directory, now: now, alive: { _ in true }))
    try JSONEncoder().encode(snapshot("failed")).write(
      to: directory.appendingPathComponent("progress-old.json"))
    try JSONEncoder().encode(snapshot("scanning", updated: 999)).write(
      to: directory.appendingPathComponent("progress-live.json"))
    let read = try XCTUnwrap(
      IndexProgressMonitor.read(directory: directory, now: now, alive: { _ in true }))
    XCTAssertEqual(read.phase, "scanning")
    XCTAssertEqual(read.count, 187_432)
    XCTAssertFalse(snapshot("writing", written: 101).valid)
    XCTAssertNil(snapshot("writing", written: 0, total: 0).fraction)
  }

  func testNativeProgressStatesRenderAtMinimumAppSize() throws {
    _ = NSApplication.shared
    let model = IndexProgressModel(hasIndex: false)
    let view = NSHostingView(
      rootView: FirstIndexProgressView(model: model, onBackground: {}, onRetry: {}, onSetup: {}))
    view.sizingOptions = []
    let window = NSWindow(
      contentRect: NSRect(x: -30_000, y: 0, width: 800, height: 572), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = view
    window.orderFront(nil)
    XCTAssertTrue(
      window.makeFirstResponder(view), "The overlay must take focus away from the browser")
    defer { window.orderOut(nil) }
    for phase in ["idle", "scanning", "building", "writing", "published", "failed", "ready"] {
      if phase != "idle" {
        model.update(
          snapshot(phase == "ready" ? "published" : phase), usableIndex: phase == "ready", now: now,
          alive: { _ in true })
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      view.layoutSubtreeIfNeeded()
      XCTAssertEqual(view.bounds.size, NSSize(width: 800, height: 572))
      let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      XCTAssertGreaterThan(data.count, 10_000)
      if let output = ProcessInfo.processInfo.environment["ZEST_PROGRESS_SNAPSHOT_DIR"] {
        let directory = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(phase).png"))
      }
    }
  }
}
