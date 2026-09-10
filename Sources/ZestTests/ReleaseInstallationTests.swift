import XCTest

@testable import Zest

final class ReleaseInstallationTests: XCTestCase {
  func testOnlyInstalledCopiesCanRegisterServices() {
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    XCTAssertTrue(
      ReleaseInstallation.isInstalled(URL(fileURLWithPath: "/Applications/Zest.app"), home: home))
    XCTAssertTrue(
      ReleaseInstallation.isInstalled(
        home.appendingPathComponent("Applications/Zest.app"), home: home))
    for path in [
      "/Volumes/Zest/Zest.app", "/tmp/Zest.app", "/Applications-fake/Zest.app",
      "/Applications/Nested/Zest.app",
    ] {
      XCTAssertFalse(ReleaseInstallation.isInstalled(URL(fileURLWithPath: path), home: home))
    }
  }

  func testMissingBundledHelperNeverFallsBackToDevelopmentOrInstalledCopy() {
    XCTAssertNil(
      ReleaseInstallation.bundledHelper(in: URL(fileURLWithPath: "/nonexistent/Zest.app")))
  }
}
