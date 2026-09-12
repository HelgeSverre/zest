import XCTest

@testable import Zest

final class IndexerMenuTests: XCTestCase {
  func testOnboardingNavigationAndVerificationNeverAutoStarts() {
    _ = NSApplication.shared
    var starts = 0
    let setup = IndexerAccessSetupController(helper: URL(fileURLWithPath: "/tmp/zest-indexer")) {
      starts += 1
    }
    XCTAssertEqual(setup.model.step, .welcome)
    setup.model.back()
    XCTAssertEqual(setup.model.step, .welcome)
    setup.nextStep()
    XCTAssertEqual(setup.model.step, .access)
    XCTAssertEqual(setup.model.primaryTitle, "Open System Settings")
    // Avoid opening the user's real Settings in automated tests.
    setup.model.settingsOpened = true
    setup.nextStep()
    XCTAssertEqual(setup.model.step, .verify)
    setup.nextStep()
    XCTAssertEqual(starts, 0)
    setup.updateAccessStatus(.verified)
    XCTAssertEqual(starts, 0)
    setup.model.back()
    XCTAssertEqual(setup.model.step, .access)
    XCTAssertEqual(setup.model.primaryTitle, "Continue")
    setup.nextStep()
    setup.nextStep()
    setup.nextStep()
    XCTAssertEqual(starts, 1)
  }

  /// Preparation stops a running indexer, so closing the window without
  /// finishing must hand control back — otherwise indexing stays off silently.
  func testDismissingTheWindowResumesButFinishingDoesNot() throws {
    _ = NSApplication.shared
    var starts = 0
    var cancels = 0
    let dismissed = IndexerAccessSetupController(
      helper: URL(fileURLWithPath: "/tmp/zest-indexer"),
      verify: { .unavailable },
      onCancel: { cancels += 1 }, onStart: { starts += 1 })
    let window = try XCTUnwrap(dismissed.window)
    window.setFrameOrigin(NSPoint(x: -30_000, y: 0))
    window.orderFront(nil)
    window.performClose(nil)
    XCTAssertEqual(cancels, 1)
    XCTAssertEqual(starts, 0)

    let finished = IndexerAccessSetupController(
      helper: URL(fileURLWithPath: "/tmp/zest-indexer"),
      verify: { .unavailable },
      onCancel: { cancels += 1 }, onStart: { starts += 1 })
    let second = try XCTUnwrap(finished.window)
    second.setFrameOrigin(NSPoint(x: -30_000, y: 0))
    second.orderFront(nil)
    finished.skipSetup(nil)
    XCTAssertEqual(starts, 1)
    XCTAssertEqual(cancels, 1, "Finishing setup must not also fire the resume path")
  }

  func testNativeOnboardingRendersAllPanels() throws {
    _ = NSApplication.shared
    let helper = URL(
      fileURLWithPath: "/Users/example/Library/Application Support/zest/bin/zest-indexer")
    let setup = IndexerAccessSetupController(
      helper: helper,
      verify: {
        XCTFail("Visual snapshots must not probe real permissions")
        return .unavailable
      }, onStart: { XCTFail("Visual snapshots must not start indexing") })
    let window = try XCTUnwrap(setup.window)
    window.setFrameOrigin(NSPoint(x: -30_000, y: 0))
    // Realize the actual NSHostingView without starting the controller's poller.
    window.orderFront(nil)
    defer { setup.cancelSetup(nil) }
    let cases: [(String, IndexerOnboardingStep, IndexerAccessStatus?)] = [
      ("welcome", .welcome, nil), ("access", .access, nil),
      ("waiting", .verify, .denied), ("verified", .verify, .verified),
      ("unavailable", .verify, .unavailable),
    ]
    for (name, step, status) in cases {
      setup.model.step = step
      setup.model.status = status
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      let content = try XCTUnwrap(window.contentView)
      content.layoutSubtreeIfNeeded()
      XCTAssertEqual(content.bounds.size, NSSize(width: 860, height: 650))
      let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
      content.cacheDisplay(in: content.bounds, to: bitmap)
      let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      XCTAssertGreaterThan(data.count, 10_000, "\(name) must contain rendered content")
      if let path = ProcessInfo.processInfo.environment["ZEST_ONBOARDING_SNAPSHOT_DIR"] {
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
      }
    }
  }

  func testNativeMenuLoadsCurrentStatusAndActions() throws {
    _ = NSApplication.shared
    let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("zig-out/bin/zest-indexer")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
    let expected: IndexerState
    do { expected = try CommandLineIndexerService(helper: helper).state() } catch {
      throw XCTSkip("No usable launchd login domain: \(error)")
    }
    let controller = IndexerMenuController(helper: helper)
    controller.menuWillOpen(controller.menu)
    let deadline = Date().addingTimeInterval(5)
    while controller.menu.items.first?.title == "Indexer: Checking…" && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertEqual(controller.menu.items.first?.title, expected.title)
    XCTAssertEqual(
      controller.menu.items.compactMap { $0.representedObject as? String },
      expected.actions.map(\.rawValue))
  }

  func testActionsReflectDaemonLifecycle() {
    XCTAssertEqual(IndexerState.notInstalled.actions, [.install])
    XCTAssertEqual(IndexerState.stopped.actions, [.start, .permissions, .uninstall])
    XCTAssertEqual(
      IndexerState.running.actions, [.reindex, .stop, .restart, .permissions, .uninstall])
    XCTAssertEqual(IndexerState.waiting.actions, [.stop, .restart, .permissions, .uninstall])
    XCTAssertNil(IndexerState(rawValue: "unknown"))
  }

  func testFailedControlProcessReportsFailure() {
    XCTAssertThrowsError(
      try IndexerProcess.run(URL(fileURLWithPath: "/usr/bin/false"), arguments: []))
  }

  func testAccessSetupCannotStartScanningDuringPreparation() {
    let helper = URL(fileURLWithPath: "/Applications Support/zest/bin/zest-indexer")
    XCTAssertEqual(IndexerAccessSetup.install.preparationCommands, [["prepare-install"]])
    XCTAssertEqual(
      IndexerAccessSetup.existing.preparationCommands, [["stop"], ["prepare-install"]])
    XCTAssertEqual(
      IndexerAccessSetup.install.completionArguments(helper: helper),
      ["install", "--binary-path", helper.path])
    XCTAssertEqual(IndexerAccessSetup.existing.completionArguments(helper: helper), ["start"])
  }

  func testAccessWindowRequiresExplicitStartAndDoesNotStartOnCancel() {
    _ = NSApplication.shared
    var starts = 0
    let setup = IndexerAccessSetupController(helper: URL(fileURLWithPath: "/tmp/zest-indexer")) {
      starts += 1
    }
    XCTAssertEqual(starts, 0)
    setup.cancelSetup(nil)
    XCTAssertEqual(starts, 0)
    let accepted = IndexerAccessSetupController(helper: URL(fileURLWithPath: "/tmp/zest-indexer")) {
      starts += 1
    }
    accepted.startIndexing(nil)
    XCTAssertEqual(starts, 0)
    XCTAssertFalse(accepted.model.canFinish)
    accepted.updateAccessStatus(.verified)
    XCTAssertTrue(accepted.model.canFinish)
    accepted.updateAccessStatus(.denied)
    XCTAssertFalse(accepted.model.canFinish)
    accepted.startIndexing(nil)
    XCTAssertEqual(starts, 0)
    accepted.updateAccessStatus(.unavailable)
    XCTAssertFalse(accepted.model.canFinish)
    accepted.updateAccessStatus(.verified)
    accepted.startIndexing(nil)
    accepted.startIndexing(nil)
    XCTAssertEqual(starts, 1)
  }

  func testSkipStartsOnceWithoutAccessButCancelNeverStarts() {
    _ = NSApplication.shared
    var starts = 0
    let setup = IndexerAccessSetupController(helper: URL(fileURLWithPath: "/tmp/zest-indexer")) {
      starts += 1
    }
    setup.skipSetup(nil)
    setup.skipSetup(nil)
    XCTAssertEqual(starts, 1)
    let cancelled = IndexerAccessSetupController(helper: URL(fileURLWithPath: "/tmp/zest-indexer"))
    { starts += 1 }
    cancelled.cancelSetup(nil)
    cancelled.skipSetup(nil)
    XCTAssertEqual(starts, 1)
  }

  func testLiveCheckUpdatesDoneAndIgnoresResultsAfterClose() {
    _ = NSApplication.shared
    let checked = expectation(description: "checked")
    let setup = IndexerAccessSetupController(
      helper: URL(fileURLWithPath: "/tmp/zest-indexer"),
      verify: {
        checked.fulfill()
        return .verified
      }, onStart: {})
    setup.showWindow(nil)
    wait(for: [checked], timeout: 2)
    let deadline = Date().addingTimeInterval(2)
    while !setup.model.canFinish && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(setup.model.canFinish)
    setup.cancelSetup(nil)

    let started = expectation(description: "late check started")
    let release = DispatchSemaphore(value: 0)
    let finished = expectation(description: "late check finished")
    let closed = IndexerAccessSetupController(
      helper: URL(fileURLWithPath: "/tmp/zest-indexer"),
      verify: {
        started.fulfill()
        _ = release.wait(timeout: .now() + 3)
        finished.fulfill()
        return .verified
      }, onStart: { XCTFail("Closing must not start indexing") })
    closed.showWindow(nil)
    wait(for: [started], timeout: 2)
    closed.pollAccess()  // Must not start an overlapping check.
    closed.cancelSetup(nil)
    release.signal()
    wait(for: [finished], timeout: 2)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    XCTAssertFalse(closed.model.canFinish)
    closed.pollAccess()  // Closed windows must not start new checks.
  }

  func testLaunchdAccessProbeWithoutProtectedFoldersIsInconclusive() throws {
    let helper = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("zig-out/bin/zest-indexer")
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(
      "zest-probe-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: home) }
    XCTAssertEqual(try IndexerAccessVerifier.check(helper: helper, home: home), .unavailable)
    // An ordinary fixture directory proves the helper actually ran. This does
    // not exercise or alter the real user's privacy permissions.
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent("Library/Safari"), withIntermediateDirectories: true)
    XCTAssertEqual(try IndexerAccessVerifier.check(helper: helper, home: home), .verified)
  }

  func testUnrecognizedStatusIsNotTreatedAsStopped() {
    XCTAssertThrowsError(
      try CommandLineIndexerService(helper: URL(fileURLWithPath: "/usr/bin/true")).state())
  }
}
