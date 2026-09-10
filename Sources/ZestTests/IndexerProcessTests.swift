import XCTest

@testable import Zest

final class IndexerProcessTests: XCTestCase {
  func testSharedRunnerForcesTerminationIfChildIgnoresTerm() {
    let start = Date()
    XCTAssertThrowsError(
      try IndexerProcess.run(
        URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "trap '' TERM; exec /bin/sleep 20"], timeout: 0.1))
    XCTAssertLessThan(Date().timeIntervalSince(start), 6)
  }
}
