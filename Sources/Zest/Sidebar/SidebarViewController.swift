import AppKit

/// The pinned-folders sidebar. A "PINNED" header above a vertical list of pin
/// rows (Home, Desktop, Documents, Downloads). Clicking a pin navigates the
/// coordinator there; the pin matching the current path gets the accent-soft
/// highlight + a 3pt accent leading rail. Categories come in a later phase.
final class SidebarViewController: NSViewController {
    private let coordinator: AppCoordinator
    private var rows: [PinRow] = []

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    private struct Pin {
        let label: String
        let symbol: String
        let path: String
    }

    private func pins() -> [Pin] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            Pin(label: "Home", symbol: "house", path: home),
            Pin(label: "Desktop", symbol: "display", path: (home as NSString).appendingPathComponent("Desktop")),
            Pin(label: "Documents", symbol: "doc", path: (home as NSString).appendingPathComponent("Documents")),
            Pin(label: "Downloads", symbol: "arrow.down", path: (home as NSString).appendingPathComponent("Downloads")),
        ]
    }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.panel.withAlphaComponent(0.6).cgColor
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let header = NSTextField(labelWithString: "PINNED")
        header.font = .systemFont(ofSize: 10.5, weight: .semibold)
        header.textColor = Theme.textTertiary
        header.translatesAutoresizingMaskIntoConstraints = false
        // Tracking (letter spacing) per the prototype's side-head.
        header.attributedStringValue = NSAttributedString(string: "PINNED", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: Theme.textTertiary,
            .kern: 0.95,
        ])

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)
        stack.setCustomSpacing(8, after: header)

        for pin in pins() {
            let row = PinRow(label: pin.label, symbol: pin.symbol, path: pin.path) { [weak self] path in
                self?.coordinator.navigate(to: path)
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rows.append(row)
        }

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            // Header gets a little extra leading inset to match the row text.
            header.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 8),
        ])

        refresh()
    }

    /// Update the active-pin highlight to match the coordinator's current path.
    func refresh() {
        let current = coordinator.currentPath
        for row in rows { row.setActive(row.path == current) }
    }
}

// MARK: - Pin row

/// A 30pt-tall pin row: SF Symbol + label, rounded `Theme.hover` background on
/// hover, and (when active) the `accentSoft` fill + 3pt accent leading rail.
private final class PinRow: NSView {
    let path: String
    private let onClick: (String) -> Void
    private static let accent = Theme.deriveAccent(base: Theme.defaultAccentBase, theme: .dark)

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let rail = NSView()
    private var active = false
    private var hovering = false

    init(label text: String, symbol: String, path: String, onClick: @escaping (String) -> Void) {
        self.path = path
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6

        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        icon.image = img?.withSymbolConfiguration(config)
        icon.contentTintColor = Theme.textSecondary
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = text
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = Theme.textSecondary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        rail.wantsLayer = true
        rail.layer?.backgroundColor = PinRow.accent.accent.cgColor
        rail.layer?.cornerRadius = 1.5
        rail.isHidden = true
        rail.translatesAutoresizingMaskIntoConstraints = false

        addSubview(rail)
        addSubview(icon)
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),

            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.centerYAnchor.constraint(equalTo: centerYAnchor),
            rail.widthAnchor.constraint(equalToConstant: 3),
            rail.heightAnchor.constraint(equalToConstant: 18),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setActive(_ value: Bool) {
        active = value
        rail.isHidden = !value
        label.textColor = value ? Theme.text : Theme.textSecondary
        icon.contentTintColor = value ? Theme.text : Theme.textSecondary
        updateBackground()
    }

    private func updateBackground() {
        if active {
            layer?.backgroundColor = PinRow.accent.accentSoft.cgColor
        } else if hovering {
            layer?.backgroundColor = Theme.hover.cgColor
        } else {
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        let up = window?.nextEvent(matching: [.leftMouseUp])
        if let up, bounds.contains(convert(up.locationInWindow, from: nil)) {
            onClick(path)
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
    override func mouseEntered(with event: NSEvent) { hovering = true; updateBackground() }
    override func mouseExited(with event: NSEvent)  { hovering = false; updateBackground() }
}
