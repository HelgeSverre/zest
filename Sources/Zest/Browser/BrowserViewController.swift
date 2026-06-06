import AppKit

final class BrowserViewController: NSViewController {
    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.background.cgColor
        let label = NSTextField(labelWithString: "FILE LIST — Name · Size · Modified · Kind · Ext")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = Theme.textTertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            label.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
        ])
        view = v
    }
}
