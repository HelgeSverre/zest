import XCTest

@testable import Zest

final class LaunchOptionsTests: XCTestCase {
  let cwd = FileManager.default.temporaryDirectory.standardizedFileURL.path

  func testFlags() {
    XCTAssertEqual(LaunchOptions.parse(["--help"], cwd: cwd), .success(.help))
    XCTAssertEqual(LaunchOptions.parse(["-V"], cwd: cwd), .success(.version))
    XCTAssertEqual(LaunchOptions.parse([], cwd: cwd), .success(.browse(path: nil)))
    XCTAssertEqual(
      LaunchOptions.parse(["--snapshot", "/tmp/x.png", "800x600"], cwd: cwd),
      .success(.snapshot(path: "/tmp/x.png", size: NSSize(width: 800, height: 600))))
  }

  func testPathResolvesAgainstCwd() {
    XCTAssertEqual(LaunchOptions.parse(["."], cwd: cwd), .success(.browse(path: cwd)))
    XCTAssertEqual(LaunchOptions.parse([cwd], cwd: "/"), .success(.browse(path: cwd)))
    XCTAssertEqual(AppCoordinator(startPath: cwd).currentPath, cwd)
  }

  func testErrors() {
    XCTAssertEqual(
      LaunchOptions.parse(["--bogus"], cwd: cwd), .failure(.usage("unknown option '--bogus'")))
    XCTAssertEqual(
      LaunchOptions.parse(["a", "b"], cwd: cwd), .failure(.usage("unexpected argument 'b'")))
    XCTAssertEqual(LaunchOptions.parse(["--snapshot"], cwd: cwd).map { _ in 0 }.exitCode, 2)
    XCTAssertEqual(
      LaunchOptions.parse(["definitely-missing-dir"], cwd: cwd).map { _ in 0 }.exitCode, 1)
    XCTAssertTrue(LaunchOptions.version.hasPrefix("Zest "))
  }
}

extension Result where Failure == LaunchError {
  fileprivate var exitCode: Int32? {
    if case .failure(let e) = self { return e.exitCode }
    return nil
  }
}
