import AppKit

/// The real toolbar band (56pt): back / forward / up nav buttons + an editable
/// breadcrumb. Leading inset of 88 clears the traffic lights. Search + saved
/// filters are deferred to a later phase, so the trailing area is left empty.
final class ToolbarView: NSView {
    private let coordinator: AppCoordinator

    private let backButton: IconButton
    private let forwardButton: IconButton
    private let upButton: IconButton
    private let breadcrumb: Breadcrumb

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.backButton = IconButton(symbol: "chevron.left", help: "Back")
        self.forwardButton = IconButton(symbol: "chevron.right", help: "Forward")
        self.upButton = IconButton(symbol: "arrow.up", help: "Enclosing folder")
        self.breadcrumb = Breadcrumb(coordinator: coordinator)

        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = Theme.panel.cgColor

        backButton.onClick = { [weak coordinator] in coordinator?.goBack() }
        forwardButton.onClick = { [weak coordinator] in coordinator?.goForward() }
        upButton.onClick = { [weak coordinator] in coordinator?.goUp() }

        let navStack = NSStackView(views: [backButton, forwardButton, upButton])
        navStack.orientation = .horizontal
        navStack.spacing = 2
        navStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(navStack)
        addSubview(breadcrumb)

        NSLayoutConstraint.activate([
            navStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 88),
            navStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            breadcrumb.leadingAnchor.constraint(equalTo: navStack.trailingAnchor, constant: 12),
            breadcrumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            breadcrumb.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])

        // The breadcrumb may grow but shouldn't pin to the trailing edge: cap it
        // like the prototype (max ~360) yet let it shrink on narrow windows.
        let maxWidth = breadcrumb.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        maxWidth.priority = .defaultHigh
        maxWidth.isActive = true

        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    /// Update enabled/disabled state for back/forward and the breadcrumb display.
    func refresh() {
        backButton.setEnabled(coordinator.canGoBack)
        forwardButton.setEnabled(coordinator.canGoForward)
        breadcrumb.refresh()
    }
}

// MARK: - Icon button

/// A 28×28 borderless, layer-backed button rendering an SF Symbol in
/// `Theme.textSecondary`, with a `Theme.hover` rounded background on hover.
/// When disabled it dims to 0.35 alpha and stops accepting clicks.
final class IconButton: NSView {
    var onClick: (() -> Void)?

    private let imageView = NSImageView()
    private var enabled = true
    private var hovering = false

    init(symbol: String, help: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        toolTip = help

        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        imageView.image = img?.withSymbolConfiguration(config)
        imageView.contentTintColor = Theme.textSecondary
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        alphaValue = value ? 1.0 : 0.35
        if !value { hovering = false; layer?.backgroundColor = NSColor.clear.cgColor }
    }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        // Confirm the mouse-up lands inside before firing (standard button feel).
        let up = window?.nextEvent(matching: [.leftMouseUp])
        if let up, bounds.contains(convert(up.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        guard enabled else { return }
        hovering = true
        layer?.backgroundColor = Theme.hover.cgColor
        imageView.contentTintColor = Theme.text
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        layer?.backgroundColor = NSColor.clear.cgColor
        imageView.contentTintColor = Theme.textSecondary
    }
}
