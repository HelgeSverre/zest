import Foundation
import XCTest

@testable import Zest

final class PreviewStateTests: XCTestCase {
  private let markdown = URL(fileURLWithPath: "/tmp/readme.md")
  private let image = URL(fileURLWithPath: "/tmp/photo.png")

  func testRequestRoutesSupportedTextToCustomPreview() {
    XCTAssertEqual(
      PreviewRequest.route(url: markdown, isRegularFile: true),
      .custom(markdown, .markdown)
    )
  }

  func testRequestRoutesOtherFilesAndDirectoriesToQuickLook() {
    XCTAssertEqual(
      PreviewRequest.route(url: image, isRegularFile: true),
      .quickLook(image)
    )
    XCTAssertEqual(
      PreviewRequest.route(url: URL(fileURLWithPath: "/tmp/folder"), isRegularFile: false),
      .quickLook(URL(fileURLWithPath: "/tmp/folder"))
    )
  }

  func testSpaceOpensRequestedSurfaceWhenClosed() {
    XCTAssertEqual(
      PreviewState.reduce(.closed, event: .toggle(.custom(markdown, .markdown))),
      .custom(markdown, .markdown)
    )
  }

  func testSpaceClosesEitherOpenSurface() {
    XCTAssertEqual(
      PreviewState.reduce(.custom(markdown, .markdown), event: .toggle(.quickLook(image))),
      .closed
    )
    XCTAssertEqual(
      PreviewState.reduce(.quickLook(image), event: .toggle(.custom(markdown, .markdown))),
      .closed
    )
  }

  func testSelectionChangeKeepsClosedPreviewClosed() {
    XCTAssertEqual(
      PreviewState.reduce(.closed, event: .selectionChanged(.quickLook(image))),
      .closed
    )
  }

  func testSelectionChangeUpdatesAndCanSwitchSurface() {
    XCTAssertEqual(
      PreviewState.reduce(
        .custom(markdown, .markdown),
        event: .selectionChanged(.quickLook(image))
      ),
      .quickLook(image)
    )
    XCTAssertEqual(
      PreviewState.reduce(
        .quickLook(image),
        event: .selectionChanged(.custom(markdown, .markdown))
      ),
      .custom(markdown, .markdown)
    )
  }

  func testCloseAlwaysClosesPreview() {
    XCTAssertEqual(
      PreviewState.reduce(.quickLook(image), event: .close),
      .closed
    )
  }
}
