import AppKit
import XCTest

@testable import Zest

final class ThemeTests: XCTestCase {
  func testLightAccentGetsDarkOnAccentText() {
    let lime = NSColor(srgbRed: 0.72, green: 1.0, blue: 0.235, alpha: 1)
    XCTAssertTrue(Theme.relativeLuminance(lime) > 0.6)
    XCTAssertEqual(Theme.onAccent(forBase: lime, theme: .dark), Theme.nearBlack)
  }

  func testBlueAccentGetsWhiteOnAccentText() {
    let blue = NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1)
    XCTAssertTrue(Theme.relativeLuminance(blue) < 0.6)
    XCTAssertEqual(Theme.onAccent(forBase: blue, theme: .dark), .white)
  }

  func testLightThemeAlwaysUsesWhiteOnAccent() {
    let lime = NSColor(srgbRed: 0.72, green: 1.0, blue: 0.235, alpha: 1)
    XCTAssertEqual(Theme.onAccent(forBase: lime, theme: .light), .white)
  }
}
