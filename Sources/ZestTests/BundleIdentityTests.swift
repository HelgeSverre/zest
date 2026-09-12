import XCTest

@testable import Zest

final class BundleIdentityTests: XCTestCase {
  /// Homebrew's `zest` is a symlink into the bundle; without a re-exec the
  /// process reports the symlink's directory as its bundle and every
  /// Info.plist / Contents/Helpers lookup fails.
  func testSymlinkedInvocationReexecsThroughTheResolvedPath() throws {
    let directory = URL(
      fileURLWithPath: NSTemporaryDirectory(), isDirectory: true
    ).appendingPathComponent("zest-bundle-identity-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let real = directory.appendingPathComponent("Zest-bundled").path
    XCTAssertTrue(FileManager.default.createFile(atPath: real, contents: Data()))
    let link = directory.appendingPathComponent("zest-linked").path
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: real)

    let target = try XCTUnwrap(BundleIdentity.reexecTarget(invoked: link))
    XCTAssertEqual(URL(fileURLWithPath: target).resolvingSymlinksInPath().path, target)
    // Re-running against the resolved path must not exec again.
    XCTAssertNil(BundleIdentity.reexecTarget(invoked: target))
  }

  func testRelativeInvocationIsLeftAlone() {
    XCTAssertNil(BundleIdentity.reexecTarget(invoked: "zest"))
    XCTAssertNil(BundleIdentity.reexecTarget(invoked: "./Zest"))
  }
}
