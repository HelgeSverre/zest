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
    XCTAssertThrowsError(
      try BundledIndexerService.state(
        authorization: .notFound, previouslySetUp: false, running: false))
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
      helper: helper, defaults: defaults, registration: registration
    ) { executable, arguments in
      commands.append(arguments)
      if executable.lastPathComponent == "launchctl" {
        throw NSError(
          domain: "fixture", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Could not find service"])
      }
      return arguments == ["status"] ? "running\n" : ""
    }
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
      helper: URL(fileURLWithPath: "/fixture"), registration: registration
    ) { _, _ in
      throw NSError(
        domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"]
      )
    }
    XCTAssertThrowsError(try service.state())
    XCTAssertThrowsError(try service.execute(["restart"]))
    XCTAssertEqual(registration.registrations, 0)
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
      registration: registration
    ) { _, arguments in
      XCTAssertEqual(arguments.first, "print")
      XCTAssertEqual(registration.unregistrations, 1)
      XCTAssertEqual(registration.registrations, 0, "Never register while the old job exists")
      polls += 1
      if polls == 1 { return "state = running" }
      throw NSError(
        domain: "fixture", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not find service"])
    }
    _ = try service.execute(["restart"])
    XCTAssertEqual(polls, 2)
    XCTAssertEqual(registration.registrations, 1)
    XCTAssertTrue(defaults.bool(forKey: "indexerSetupCompleted"))
  }
}
