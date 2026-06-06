import AppKit

final class SidebarViewController: NSViewController {
    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.panel.withAlphaComponent(0.6).cgColor
        let label = NSTextField(labelWithString: "SIDEBAR — pinned · categories")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Theme.textTertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            label.topAnchor.constraint(equalTo: v.topAnchor, constant: 18),
        ])
        view = v
    }
}
