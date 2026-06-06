import AppKit

/// The window's root: a vibrancy backdrop plus the chrome bands and the
/// sidebar|content split, laid out with explicit Auto Layout constraints.
/// (A vertical NSStackView collapsed the split view to the sidebar's min width
/// instead of stretching it full-width, so we constrain everything directly.)
final class RootViewController: NSViewController {
    private let splitVC = NSSplitViewController()
    private let coordinator = AppCoordinator()

    private var toolbar: ToolbarView!
    private var filterBar: FilterBarView!
    private var sidebar: SidebarViewController!
    private var browser: BrowserViewController!

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
        let statusBar = PlaceholderBand(title: "STATUS BAR — indexed count · selection · freshness", fill: Theme.panel)

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

        // The coordinator is the single source of truth. Navigation (toolbar,
        // sidebar, breadcrumb, double-click) resets the query+scope, then refreshes
        // every observer — toolbar clears the search field, filter bar resets to
        // "This folder" + recomputes the count.
        coordinator.onChange = { [weak self] in
            guard let self else { return }
            self.browser.reload()
            self.toolbar.refresh()
            self.filterBar.refresh()
            self.sidebar.refresh()
        }
        // Query/scope/sort changes (search field, scope control, header click)
        // refresh the list + count + filter bar without a full navigation.
        coordinator.onResultsChange = { [weak self] in
            guard let self else { return }
            self.browser.reload()
            self.filterBar.refresh()
            self.toolbar.refresh()
        }
        // Initial refresh so the breadcrumb/sidebar/filter bar reflect the start.
        toolbar.refresh()
        filterBar.refresh()
        sidebar.refresh()
    }
}
