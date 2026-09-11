import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow!
  private let indexerMenu = IndexerMenuController()
  /// Set by `RootViewController.viewDidAppear` so menu actions (Go Up, Open
  /// Selected) can reach the coordinator and the active browser. Weak so we
  /// don't extend the controller's lifetime past its window.
  weak var rootViewController: RootViewController?
  /// Absolute folder from `zest PATH`, or nil for `$HOME`.
  private let startPath: String?

  init(startPath: String? = nil) {
    self.startPath = startPath
    super.init()
  }

  func setUpIndexer() { indexerMenu.setUpAccess() }
  func retryIndexer() { indexerMenu.retryIndexing() }

  func applicationDidFinishLaunching(_: Notification) {
    installMainMenu()

    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false,
    )
    win.titleVisibility = .hidden
    win.titlebarAppearsTransparent = true
    win.isMovableByWindowBackground = true
    win.backgroundColor = Theme.background
    win.minSize = NSSize(width: 800, height: 600)
    win.appearance = NSAppearance(named: .darkAqua)
    win.title = "Zest"
    win.contentViewController = RootViewController(
      coordinator: AppCoordinator(startPath: startPath))
    win.setContentSize(NSSize(width: 1180, height: 760))
    win.center()
    win.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window = win
    indexerMenu.refreshOnLaunch()
  }

  // MARK: Main menu

  /// Install the standard Application / File / Edit / View / Navigation /
  /// Window / Help menu bar. Without an explicit main menu, AppKit drops ⌘
  /// shortcuts (and the responder chain can't dispatch Cut/Copy/Paste/Select
  /// All into the search field). Navigation carries the keyboard shortcuts
  /// that mirror the old Zig UI: ⌘↑ = Go Up, ⌘↓ = Open Selection.
  func installMainMenu() {
    let mainMenu = NSMenu()
    let indexMenuItem = NSMenuItem()
    indexMenuItem.submenu = indexerMenu.menu
    for item in [
      makeAppMenu(), makeFileMenu(), makeEditMenu(), makeViewMenu(), indexMenuItem,
      makeNavigationMenu(), makeWindowMenu(), makeMenu("Help", items: []),
    ] {
      mainMenu.addItem(item)
    }
    NSApp.mainMenu = mainMenu
  }

  /// Application menu (titled with the process name automatically).
  private func makeAppMenu() -> NSMenuItem {
    let hideOthers = NSMenuItem(
      title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h",
    )
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    return makeMenu(
      "",
      items: [
        NSMenuItem(
          title: "About Zest", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
          keyEquivalent: ""),
        .separator(),
        NSMenuItem(
          title: "Hide Zest", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
        hideOthers,
        NSMenuItem(
          title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
          keyEquivalent: ""),
        .separator(),
        NSMenuItem(
          title: "Quit Zest", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
      ])
  }

  /// Close Window is the only universal File action we need.
  private func makeFileMenu() -> NSMenuItem {
    makeMenu(
      "File",
      items: [
        NSMenuItem(
          title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
      ])
  }

  /// These selectors walk the responder chain so Cut/Copy/Paste land in the
  /// active text field (the search field), not on a fixed target.
  private func makeEditMenu() -> NSMenuItem {
    let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    let find = NSMenuItem(title: "Find", action: #selector(menuFocusSearch(_:)), keyEquivalent: "f")
    find.target = self
    return makeMenu(
      "Edit",
      items: [
        NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"), redo,
        .separator(),
        NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
        NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
        NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
        NSMenuItem(
          title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        .separator(), find,
      ])
  }

  /// Checkmark state comes from validateMenuItem, so it stays in sync however
  /// the pref changes.
  private func makeViewMenu() -> NSMenuItem {
    let items = [
      NSMenuItem(
        title: "Folders on Top", action: #selector(menuToggleFoldersOnTop(_:)), keyEquivalent: ""),
      .separator(),
      NSMenuItem(
        title: "Focus Sidebar", action: #selector(menuFocusSidebar(_:)), keyEquivalent: "1"),
      NSMenuItem(
        title: "Focus File List", action: #selector(menuFocusFileList(_:)), keyEquivalent: "2"),
    ]
    for item in items { item.target = self }
    return makeMenu("View", items: items)
  }

  /// Keyboard shortcuts carried over from the old Zig UI: ⌘↑ Go Up, ⌘↓ Open.
  private func makeNavigationMenu() -> NSMenuItem {
    let items = [
      NSMenuItem(title: "Go Up", action: #selector(menuGoUp(_:)), keyEquivalent: "\u{F700}"),
      NSMenuItem(
        title: "Open Selected", action: #selector(menuOpenSelected(_:)), keyEquivalent: "\u{F701}"),
    ]
    for item in items {
      item.keyEquivalentModifierMask = [.command]
      item.target = self
    }
    return makeMenu("Navigation", items: items)
  }

  /// Minimize + Zoom; NSApp.windowsMenu populates the window list itself.
  private func makeWindowMenu() -> NSMenuItem {
    let item = makeMenu(
      "Window",
      items: [
        NSMenuItem(
          title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
        NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
      ])
    NSApp.windowsMenu = item.submenu
    return item
  }

  /// Build a top-level menu with the given title and items, returning the
  /// wrapping menu item ready to add to the main menu bar.
  private func makeMenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
    let menu = NSMenu(title: title)
    for it in items {
      menu.addItem(it)
    }
    let item = NSMenuItem()
    item.submenu = menu
    return item
  }

  // MARK: Menu actions

  @objc private func menuFocusSearch(_: Any?) {
    rootViewController?.focusSearch()
  }

  @objc private func menuFocusSidebar(_: Any?) {
    rootViewController?.focusSidebar()
  }

  @objc private func menuFocusFileList(_: Any?) {
    rootViewController?.focusFileList()
  }

  @objc private func menuToggleFoldersOnTop(_: Any?) {
    guard let coordinator = rootViewController?.coordinator else { return }
    coordinator.foldersOnTop.toggle()
  }

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    if item.action == #selector(menuToggleFoldersOnTop(_:)) {
      item.state = (rootViewController?.coordinator.foldersOnTop ?? false) ? .on : .off
    }
    return true
  }

  @objc private func menuGoUp(_: Any?) {
    rootViewController?.coordinator.goUp()
  }

  @objc private func menuOpenSelected(_: Any?) {
    rootViewController?.browser.openSelected()
  }
}
