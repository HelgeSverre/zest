import AppKit
import XCTest

@testable import Zest

/// Drives the real `RootViewController` in an off-screen window, in-process
/// (no XCUITest, no Accessibility permission). Same window trick as
/// `Snapshot`/`Bench`; views are located by `A11y` identifiers.
final class UIHarness {
  let window: NSWindow
  let root: RootViewController
  let coordinator: AppCoordinator
  /// Keeps the menu's action target (the delegate) alive; ⌘ shortcuts route
  /// through `NSApp.mainMenu` exactly as in the app.
  private let menuOwner = AppDelegate()
  private var landed = false

  /// Resolves the index like `ZestCoreTests`: CI's `ZEST_TEST_INDEX_PATH`
  /// fixture is mandatory, the developer's local index is optional (skip).
  static func make(file: StaticString = #filePath, line: UInt = #line) throws -> UIHarness {
    let env = ProcessInfo.processInfo.environment
    let configured = env["ZEST_TEST_INDEX_PATH"]
    let indexPath =
      configured
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("zest/index.zst").path
    let scope = env["ZEST_TEST_INDEX_SCOPE"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    if configured == nil, !FileManager.default.fileExists(atPath: indexPath) {
      throw XCTSkip("No index at \(indexPath); run `just index` first.")
    }
    let coordinator = AppCoordinator(startPath: scope, indexPath: indexPath)
    if coordinator.core == nil {
      if configured != nil {
        XCTFail("Configured fixture index is missing, empty, or incompatible: \(indexPath)")
      }
      throw XCTSkip("Local index is unreadable or from an older format; run `just index`.")
    }
    return UIHarness(coordinator: coordinator)
  }

  private init(coordinator: AppCoordinator) {
    _ = NSApplication.shared
    self.coordinator = coordinator
    root = RootViewController(coordinator: coordinator)
    window = NSWindow(
      contentRect: NSRect(x: -30_000, y: 0, width: 1180, height: 760),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentViewController = root  // loads the view; wires the original onChange
    window.setContentSize(NSSize(width: 1180, height: 760))
    window.orderFront(nil)
    menuOwner.installMainMenu()
    menuOwner.rootViewController = root
    let original = coordinator.onChange
    coordinator.onChange = { [weak self] in
      original?()
      if let self, !self.coordinator.isLoading { self.landed = true }
    }
    RunLoopPump.run(0.35)
  }

  deinit {
    window.orderOut(nil)
    NSApp.mainMenu = nil
  }

  // MARK: Finding views

  func find<T: NSView>(_ id: String, as _: T.Type = T.self, in view: NSView? = nil) -> T? {
    let start = view ?? window.contentView!
    if let v = start as? T, start.accessibilityIdentifier() == id { return v }
    for sub in start.subviews {
      if let hit: T = find(id, as: T.self, in: sub) { return hit }
    }
    return nil
  }

  func require<T: NSView>(
    _ id: String, as type: T.Type = T.self, file: StaticString = #filePath, line: UInt = #line
  ) throws -> T {
    try XCTUnwrap(find(id, as: type), "no view with identifier \(id)", file: file, line: line)
  }

  /// Text of the name cell in `row` of the browser table (nil if not realized).
  func browserCellText(row: Int) -> String? {
    guard let table: NSTableView = find(A11y.browserTable) else { return nil }
    return (table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?
      .textField?.stringValue
  }

  // MARK: Waiting

  /// Pump the run loop until a fresh result set has landed since `arm()` and
  /// no query is in flight. Fails the test on timeout.
  func settle(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
    let ok = RunLoopPump.until(timeout: timeout) { landed && !coordinator.isLoading }
    XCTAssertTrue(ok, "UI did not settle within \(timeout)s", file: file, line: line)
    RunLoopPump.run(0.05)  // let layout / cell realization catch up
  }

  /// Mark the start of an action so `settle` waits for the *next* delivery.
  func arm() { landed = false }

  // MARK: Input

  enum Key {
    case escape, `return`, up, down, left, right, delete
    var code: UInt16 {
      switch self {
      case .escape: 53
      case .return: 36
      case .up: 126
      case .down: 125
      case .left: 123
      case .right: 124
      case .delete: 51
      }
    }
    var chars: String {
      switch self {
      case .escape: "\u{1B}"
      case .return: "\r"
      case .up: "\u{F700}"
      case .down: "\u{F701}"
      case .left: "\u{F702}"
      case .right: "\u{F703}"
      case .delete: "\u{7F}"
      }
    }
  }

  /// Focus the search field and type `text` as real key events through the
  /// window's responder chain (field editor → controlTextDidChange → debounce).
  func type(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws {
    let field: NSTextField = try require(A11y.search, file: file, line: line)
    arm()
    window.makeFirstResponder(field)
    for ch in text {
      send(chars: String(ch), code: 0, modifiers: [])
    }
  }

  func press(_ key: Key, modifiers: NSEvent.ModifierFlags = []) {
    arm()
    send(chars: key.chars, code: key.code, modifiers: modifiers)
  }

  /// keyDown + keyUp. ⌘-combos are offered to the main menu first (what
  /// `NSApplication.sendEvent` does); everything else goes to the window.
  private func send(chars: String, code: UInt16, modifiers: NSEvent.ModifierFlags) {
    for type in [NSEvent.EventType.keyDown, .keyUp] {
      guard
        let e = NSEvent.keyEvent(
          with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: chars,
          charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
      else { continue }
      if type == .keyDown, modifiers.contains(.command),
        NSApp.mainMenu?.performKeyEquivalent(with: e) == true
      {
        continue
      }
      window.sendEvent(e)
    }
  }

  /// Select `row` in the browser table; `double` fires the table's doubleAction
  /// (synthesized mouse events never make `NSTableView.mouseDown` register a
  /// click in a non-key window, so this mirrors what the double-click does).
  func clickRow(_ row: Int, double: Bool = false) throws {
    let table: NSTableView = try require(A11y.browserTable)
    arm()
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    table.scrollRowToVisible(row)
    if double, let action = table.doubleAction {
      NSApp.sendAction(action, to: table.target, from: table)
    }
  }

  /// Click a custom view (sidebar row, scope chip).
  func click(_ view: NSView) {
    arm()
    click(at: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil))
  }

  /// `NSWindow.sendEvent` drops mouse-downs in a window that never became
  /// key, so the down is delivered to the hit-tested view directly (the same
  /// view the window would pick). The custom views block in
  /// `nextEvent(matching: [.leftMouseUp])` inside `mouseDown`, so the up is
  /// queued first.
  private func click(at point: NSPoint) {
    func event(_ type: NSEvent.EventType) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1,
        pressure: type == .leftMouseDown ? 1 : 0)!
    }
    guard let target = window.contentView?.hitTest(point) else { return }
    window.postEvent(event(.leftMouseUp), atStart: false)
    target.mouseDown(with: event(.leftMouseDown))
    // Drain the queued up if nobody consumed it.
    while let e = window.nextEvent(
      matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true)
    {
      target.mouseUp(with: e)
    }
  }
}
