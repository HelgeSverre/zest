import ServiceManagement
import XCTest

@testable import Zest

final class BundledIndexerServiceTests: XCTestCase {
  final class Registration: BackgroundServiceRegistration {
    var status: SMAppService.Status = .notRegistered
    var registrations = 0
    var unregistrations = 0
    var needsApproval = false
    func register() throws {
      registrations += 1
      status = needsApproval ? .requiresApproval : .enabled
    }
    func unregister() throws {
      unregistrations += 1
      status = .notRegistered
    }
  }

  func testAuthorizationIsNotMistakenForRunningOrPermissionGranted() throws {
    XCTAssertEqual(
      try BundledIndexerService.state(
        authorization: .enabled, previouslySetUp: true, running: false), .waiting)
    XCTAssertEqual(
      try BundledIndexerService.state(
        authorization: .enabled, previouslySetUp: true, running: true), .running)
    XCTAssertEqual(
      try BundledIndexerService.state(
        authorization: .requiresApproval, previouslySetUp: true, running: false), .requiresApproval)
    XCTAssertEqual(
      try BundledIndexerService.state(
        authorization: .notRegistered, previouslySetUp: false, running: false), .notInstalled)
    XCTAssertEqual(
      try BundledIndexerService.state(
        authorization: .notRegistered, previouslySetUp: true, running: false), .stopped)
    XCTAssertEqual(
      try BundledIndexerService.state(
        authorization: .notFound, previouslySetUp: false, running: false), .notInstalled)
    XCTAssertEqual(IndexerState.requiresApproval.actions, [.approveBackground, .uninstall])
  }

  func testSetupMigratesLegacyWithoutRegisteringAndDisableSurvivesRelaunch() throws {
    let suite = "dev.zest.test.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let registration = Registration()
    var commands: [[String]] = []
    let helper = URL(fileURLWithPath: "/Applications/Zest.app/Contents/Helpers/zest-indexer")
    let service = BundledIndexerService(
      helper: helper, defaults: defaults, registration: registration,
      run: { executable, arguments in
        commands.append(arguments)
        if executable.lastPathComponent == "launchctl" {
          throw NSError(
            domain: "fixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not find service"])
        }
        return arguments == ["status"] ? "running\n" : ""
      })
    XCTAssertEqual(try service.execute(["status"]), "not_installed")
    XCTAssertTrue(
      commands.isEmpty, "A fresh app must not inspect or mutate legacy services automatically")
    XCTAssertEqual(try service.execute(["prepare-install"]), helper.path)
    XCTAssertEqual(commands, [["status"], ["uninstall"]])
    XCTAssertEqual(registration.registrations, 0, "Preparing or closing setup must not start scans")
    registration.needsApproval = true
    _ = try service.execute(["install"])
    XCTAssertEqual(try service.state(), .requiresApproval)
    _ = try service.execute(["start"])
    XCTAssertEqual(
      registration.registrations, 1, "Don't repeatedly register while awaiting approval")
    _ = try service.execute(["uninstall"])
    XCTAssertEqual(try service.state(), .stopped)
    XCTAssertEqual(registration.unregistrations, 1)
    let reopened = BundledIndexerService(
      helper: helper, defaults: defaults, registration: registration)
    XCTAssertEqual(try reopened.state(), .stopped)
    XCTAssertEqual(registration.registrations, 1)
  }

  func testUnexpectedLaunchctlErrorsAreNotReportedAsWaiting() throws {
    let registration = Registration()
    registration.status = .enabled
    let service = BundledIndexerService(
      helper: URL(fileURLWithPath: "/fixture"), registration: registration,
      run: { _, _ in
        throw NSError(
          domain: "fixture", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
        )
      })
    XCTAssertThrowsError(try service.state())
    XCTAssertThrowsError(try service.execute(["restart"]))
    XCTAssertEqual(registration.registrations, 0)
  }

  func testMissingRegistrationOffersSetupWithoutUnregisteringOrStarting() throws {
    for previouslySetUp in [false, true] {
      let suite = "dev.zest.test.\(UUID().uuidString)"
      let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      defaults.set(previouslySetUp, forKey: "indexerSetupCompleted")
      let registration = Registration()
      registration.status = .notFound
      var validations = 0
      var commands: [[String]] = []
      let service = BundledIndexerService(
        helper: URL(fileURLWithPath: "/fixture/zest-indexer"), defaults: defaults,
        registration: registration, validateBundle: { validations += 1 }
      ) { _, arguments in
        commands.append(arguments)
        return "not_installed\n"
      }
      XCTAssertEqual(try service.state(), .notInstalled)
      XCTAssertEqual(try service.state().actions, [.install])
      XCTAssertTrue(commands.isEmpty)
      _ = try service.execute(["prepare-install"])
      XCTAssertEqual(commands, [["status"]])
      XCTAssertEqual(registration.unregistrations, 0)
      XCTAssertEqual(registration.registrations, 0)
      XCTAssertGreaterThan(validations, 0)
      _ = try service.execute(["install"])
      XCTAssertEqual(registration.registrations, 1)
    }
  }

  func testMissingRegistrationDoesNotHideBrokenBundle() throws {
    let registration = Registration()
    registration.status = .notFound
    let service = BundledIndexerService(
      helper: URL(fileURLWithPath: "/fixture"), registration: registration,
      validateBundle: {
        throw NSError(domain: "fixture", code: 1)
      }
    ) { _, _ in
      XCTFail("Must not run commands for a broken bundle")
      return ""
    }
    XCTAssertThrowsError(try service.state())
    XCTAssertThrowsError(try service.execute(["prepare-install"]))
    XCTAssertEqual(registration.unregistrations, 0)
    XCTAssertEqual(registration.registrations, 0)
  }

  func testBundleValidationRequiresExecutableAndMatchingAgentConfiguration() throws {
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: bundle) }
    let helper = bundle.appendingPathComponent("Contents/Helpers/zest-indexer")
    let plist = bundle.appendingPathComponent(
      "Contents/Library/LaunchAgents/dev.zest.app.indexer.plist")
    for file in [helper, plist] {
      try FileManager.default.createDirectory(
        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    XCTAssertThrowsError(try BundledIndexerService.validateBundle(at: bundle))
    try Data("fixture".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
    var properties: [String: Any] = [
      "Label": BundledIndexerService.label,
      "BundleProgram": "Contents/Helpers/zest-indexer",
      "ProgramArguments": ["zest-indexer"],
    ]
    func writePlist() throws {
      try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
        .write(to: plist)
    }
    try writePlist()
    XCTAssertNoThrow(try BundledIndexerService.validateBundle(at: bundle))
    properties["BundleProgram"] = "wrong-helper"
    try writePlist()
    XCTAssertThrowsError(try BundledIndexerService.validateBundle(at: bundle))
    properties["BundleProgram"] = "Contents/Helpers/zest-indexer"
    try writePlist()
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: helper.path)
    XCTAssertThrowsError(try BundledIndexerService.validateBundle(at: bundle))
  }

  func testRestartWaitsForOldJobToDisappearBeforeRegistering() throws {
    let suite = "dev.zest.test.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let registration = Registration()
    registration.status = .enabled
    var polls = 0
    let service = BundledIndexerService(
      helper: URL(fileURLWithPath: "/fixture"), defaults: defaults,
      registration: registration,
      run: { _, arguments in
        XCTAssertEqual(arguments.first, "print")
        XCTAssertEqual(registration.unregistrations, 1)
        XCTAssertEqual(registration.registrations, 0, "Never register while the old job exists")
        polls += 1
        if polls == 1 { return "state = running" }
        throw NSError(
          domain: "fixture", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Could not find service"])
      })
    _ = try service.execute(["restart"])
    XCTAssertEqual(polls, 2)
    XCTAssertEqual(registration.registrations, 1)
    XCTAssertTrue(defaults.bool(forKey: "indexerSetupCompleted"))
  }
}
