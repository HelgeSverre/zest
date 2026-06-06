import XCTest
@testable import Zest

final class ZestCoreTests: XCTestCase {
    private var indexPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("zest/index.zst").path
    }

    func testOpenAndQueryRealIndex() throws {
        guard FileManager.default.fileExists(atPath: indexPath) else {
            throw XCTSkip("No index at \(indexPath); run `zest-indexer --full-scan ~` first.")
        }
        let core = try XCTUnwrap(ZestCore(indexPath: indexPath))
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let rows = core.query("", scope: home, maxDepth: 1, maxResults: 5_000)
        XCTAssertFalse(rows.isEmpty, "home folder listing should return entries")
        XCTAssertFalse(rows[0].name.isEmpty)
    }

    func testOpenMissingFileReturnsNil() {
        XCTAssertNil(ZestCore(indexPath: "/nonexistent/zest/index.zst"))
    }
}
