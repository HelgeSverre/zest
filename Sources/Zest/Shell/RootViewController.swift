import AppKit

/// The window's root: a vibrancy backdrop plus the chrome bands and the
/// sidebar|content split, laid out with explicit Auto Layout constraints.
/// (A vertical NSStackView collapsed the split view to the sidebar's min width
/// instead of stretching it full-width, so we constrain everything directly.)
final class RootViewController: NSViewController {
  private let splitVC = NSSplitViewController()
  let coordinator = AppCoordinator()

  private var toolbar: ToolbarView!
  private var filterBar: FilterBarView!
  private var sidebar: SidebarViewController!
  var browser: BrowserViewController!
  private var statusBar: StatusBarView!
  private var savedFiltersCard: SavedFiltersCard!
  private var savedFiltersDialog: SavedFiltersDialog!

  override func loadView() {
    view = NSView()
    view.wantsLayer = true
    view.layer?.backgroundColor = Theme.background.cgColor
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    // Under-window vibrancy backdrop.
    let bg = NSVisualEffectView()
    bg.material = .underWindowBackground
    bg.blendingMode = .behindWindow
    bg.state = .followsWindowActiveState

    // Chrome bands + 1px dividers.
    let toolbar = ToolbarView(coordinator: coordinator)
    self.toolbar = toolbar
    let h1 = Hairline()
    let filterBar = FilterBarView(coordinator: coordinator)
    self.filterBar = filterBar
    let h2 = Hairline()
    let h3 = Hairline()
    let statusBar = StatusBarView(coordinator: coordinator)
    self.statusBar = statusBar

    // Sidebar | content split (sidebar is the leading item).
    let sidebar = SidebarViewController(coordinator: coordinator)
    let browser = BrowserViewController(coordinator: coordinator)
    self.sidebar = sidebar
    self.browser = browser
    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sidebarItem.minimumThickness = 190
    sidebarItem.maximumThickness = 260
    sidebarItem.canCollapse = false
    let browserItem = NSSplitViewItem(viewController: browser)
    splitVC.addSplitViewItem(sidebarItem)
    splitVC.addSplitViewItem(browserItem)
    splitVC.splitView.dividerStyle = .thin
    addChild(splitVC)
    let split = splitVC.view

    let bands: [NSView] = [toolbar, h1, filterBar, h2, split, h3, statusBar]
    for v in [bg] + bands {
      v.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(v)
    }

    var c: [NSLayoutConstraint] = [
      bg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bg.topAnchor.constraint(equalTo: view.topAnchor),
      bg.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ]
    for b in bands {  // every band spans full width
      c.append(b.leadingAnchor.constraint(equalTo: view.leadingAnchor))
      c.append(b.trailingAnchor.constraint(equalTo: view.trailingAnchor))
    }
    c += [  // vertical chain; the split flexes to fill the middle
      toolbar.topAnchor.constraint(equalTo: view.topAnchor),
      toolbar.heightAnchor.constraint(equalToConstant: 56),
      h1.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
      h1.heightAnchor.constraint(equalToConstant: 1),
      filterBar.topAnchor.constraint(equalTo: h1.bottomAnchor),
      filterBar.heightAnchor.constraint(equalToConstant: 42),
      h2.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
      h2.heightAnchor.constraint(equalToConstant: 1),
      split.topAnchor.constraint(equalTo: h2.bottomAnchor),
      h3.topAnchor.constraint(equalTo: split.bottomAnchor),
      h3.heightAnchor.constraint(equalToConstant: 1),
      statusBar.topAnchor.constraint(equalTo: h3.bottomAnchor),
      statusBar.heightAnchor.constraint(equalToConstant: 28),
      statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ]
    NSLayoutConstraint.activate(c)

    // Saved-filters overlays, mounted above every band (card first, the
    // dialog scrim last so it also covers an open card). Hidden until shown.
    let card = SavedFiltersCard(coordinator: coordinator)
    let dialog = SavedFiltersDialog(coordinator: coordinator)
    savedFiltersCard = card
    savedFiltersDialog = dialog
    view.addSubview(card)
    view.addSubview(dialog)
    NSLayoutConstraint.activate([
      // Prototype .popover: top 52, right 14, width 280 (4pt up into the toolbar).
      card.topAnchor.constraint(equalTo: view.topAnchor, constant: 52),
      card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
      card.widthAnchor.constraint(equalToConstant: 280),
      card.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
      dialog.topAnchor.constraint(equalTo: view.topAnchor),
      dialog.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      dialog.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      dialog.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
    toolbar.onSavedClick = { [weak self] in self?.savedFiltersCard.toggle() }
    card.toggleExclusionView = toolbar.savedButtonView
    card.onManage = { [weak self] in self?.savedFiltersDialog.show() }
    card.onSaveCurrent = { [weak self] query in
      self?.savedFiltersDialog.show(prefillQuery: query)
    }

    // The coordinator is the single source of truth. Any state change —
    // navigation, query text, scope, or sort — refreshes every observer.
    coordinator.onChange = { [weak self] in
      guard let self else { return }
      self.browser.reload()
      self.toolbar.refresh()
      self.filterBar.refresh()
      self.sidebar.refresh()
      self.statusBar.refresh()
    }
    coordinator.startIndexReloadTimer()
    // The browser's selection drives the status bar's center summary.
    browser.onSelectionChange = { [weak self] summary in
      self?.statusBar.setSelection(summary)
    }
    // Initial refresh so the breadcrumb/sidebar/filter bar/status bar reflect the start.
    toolbar.refresh()
    filterBar.refresh()
    sidebar.refresh()
    statusBar.refresh()
    // Seed the center summary from the browser's default (row 0) selection —
    // its first `reload()` ran before `onSelectionChange` was wired.
    statusBar.setSelection(browser.currentSelectionSummary())
    // Kick the initial query now that every observer is wired: the empty
    // snapshot renders immediately and the first off-main delivery fires a
    // second onChange with the real rows.
    coordinator.start()
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    // Hand the controller to the AppDelegate so menu actions (Go Up, Open
    // Selected) can reach the coordinator and the active browser.
    (NSApp.delegate as? AppDelegate)?.rootViewController = self
  }
}
