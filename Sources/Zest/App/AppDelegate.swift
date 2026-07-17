import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var window: NSWindow!
  /// Set by `RootViewController.viewDidAppear` so menu actions (Go Up, Open
  /// Selected) can reach the coordinator and the active browser. Weak so we
  /// don't extend the controller's lifetime past its window.
  weak var rootViewController: RootViewController?

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
    win.contentViewController = RootViewController()
    win.setContentSize(NSSize(width: 1180, height: 760))
    win.center()
    win.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window = win
  }

  // MARK: Main menu

  /// Install the standard Application / File / Edit / View / Navigation /
  /// Window / Help menu bar. Without an explicit main menu, AppKit drops ⌘
  /// shortcuts (and the responder chain can't dispatch Cut/Copy/Paste/Select
  /// All into the search field). Navigation carries the keyboard shortcuts
  /// that mirror the old Zig UI: ⌘↑ = Go Up, ⌘↓ = Open Selection.
  private func installMainMenu() {
    let mainMenu = NSMenu()

    // Application menu (titled with the process name automatically).
    let appMenuItem = NSMenuItem()
    mainMenu.addItem(appMenuItem)
    let appMenu = NSMenu()
    appMenu.addItem(
      withTitle: "About Zest", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: "",
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Hide Zest", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h",
    )
    let hideOthers = NSMenuItem(
      title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h",
    )
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(hideOthers)
    appMenu.addItem(
      withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: "",
    )
    appMenu.addItem(.separator())
    appMenu.addItem(
      withTitle: "Quit Zest", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q",
    )
    appMenuItem.submenu = appMenu

    // File menu — Close Window is the only universal File action we need.
    mainMenu.addItem(
      makeMenu(
        "File",
        items: [
          NSMenuItem(
            title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w",
          )
        ],
      ),
    )

    // Edit menu — these selectors walk the responder chain so Cut/Copy/Paste
    // land in the active text field (the search field), not on a fixed target.
    let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    let cut = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    let selectAll = NSMenuItem(
      title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a",
    )
    mainMenu.addItem(
      makeMenu("Edit", items: [undo, redo, .separator(), cut, copy, paste, selectAll]),
    )

    // View menu. Checkmark state comes from validateMenuItem, so it stays in
    // sync however the pref changes.
    let foldersOnTop = NSMenuItem(
      title: "Folders on Top", action: #selector(menuToggleFoldersOnTop(_:)), keyEquivalent: "",
    )
    foldersOnTop.target = self
    mainMenu.addItem(makeMenu("View", items: [foldersOnTop]))

    // Navigation — the new keyboard shortcuts from the old Zig UI.
    let navMenu = NSMenu(title: "Navigation")
    let goUp = NSMenuItem(
      title: "Go Up", action: #selector(menuGoUp(_:)), keyEquivalent: "\u{F700}",
    )
    goUp.keyEquivalentModifierMask = [.command]
    goUp.target = self
    navMenu.addItem(goUp)

    let openSel = NSMenuItem(
      title: "Open Selected", action: #selector(menuOpenSelected(_:)), keyEquivalent: "\u{F701}",
    )
    openSel.keyEquivalentModifierMask = [.command]
    openSel.target = self
    navMenu.addItem(openSel)

    let navMenuItem = NSMenuItem()
    navMenuItem.submenu = navMenu
    mainMenu.addItem(navMenuItem)

    // Window menu — Minimize + Zoom; NSApp.windowsMenu will populate the
    // window list automatically once we install this.
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(
      withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m",
    )
    windowMenu.addItem(
      withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "",
    )
    let windowMenuItem = NSMenuItem()
    windowMenuItem.submenu = windowMenu
    mainMenu.addItem(windowMenuItem)
    NSApp.windowsMenu = windowMenu

    // Help menu — placeholder, keeps the bar balanced.
    mainMenu.addItem(makeMenu("Help", items: []))

    NSApp.mainMenu = mainMenu
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
