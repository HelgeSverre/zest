import AppKit

final class RootViewController: NSViewController {
    private let splitVC = NSSplitViewController()

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = Theme.background.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Background material (under-window vibrancy)
        let bg = NSVisualEffectView()
        bg.material = .underWindowBackground
        bg.blendingMode = .behindWindow
        bg.state = .followsWindowActiveState
        bg.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bg)
        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bg.topAnchor.constraint(equalTo: view.topAnchor),
            bg.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Bands
        let toolbar = PlaceholderBand(title: "TOOLBAR — nav · breadcrumb · search · saved", fill: Theme.panel, leadingInset: 88)
        let filterBar = PlaceholderBand(title: "FILTER BAR — scope · chips · count · sort", fill: Theme.panel)
        let statusBar = PlaceholderBand(title: "STATUS BAR — indexed count · selection · freshness", fill: Theme.panel)
        toolbar.heightAnchor.constraint(equalToConstant: 56).isActive = true
        filterBar.heightAnchor.constraint(equalToConstant: 42).isActive = true
        statusBar.heightAnchor.constraint(equalToConstant: 28).isActive = true

        // Split: sidebar | content
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

        let stack = NSStackView(views: [toolbar, Hairline(), filterBar, Hairline(), splitVC.view, Hairline(), statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        // The split view band must take all remaining vertical space.
        splitVC.view.setContentHuggingPriority(.defaultLow, for: .vertical)
        splitVC.view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    }
}
