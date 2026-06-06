import AppKit

/// The window's root: a vibrancy backdrop plus the chrome bands and the
/// sidebar|content split, laid out with explicit Auto Layout constraints.
/// (A vertical NSStackView collapsed the split view to the sidebar's min width
/// instead of stretching it full-width, so we constrain everything directly.)
final class RootViewController: NSViewController {
    private let splitVC = NSSplitViewController()

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
        let toolbar = PlaceholderBand(title: "TOOLBAR — nav · breadcrumb · search · saved", fill: Theme.panel, leadingInset: 88)
        let h1 = Hairline()
        let filterBar = PlaceholderBand(title: "FILTER BAR — scope · chips · count · sort", fill: Theme.panel)
        let h2 = Hairline()
        let h3 = Hairline()
        let statusBar = PlaceholderBand(title: "STATUS BAR — indexed count · selection · freshness", fill: Theme.panel)

        // Sidebar | content split (sidebar is the leading item).
        let sidebar = SidebarViewController()
        let browser = BrowserViewController()
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
    }
}
