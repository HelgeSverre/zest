import AppKit

// MARK: - Model

/// Display-ready row for the file list. Computed once from a ZestCore.Row so the
/// table delegate does no formatting work per cell draw.
struct FileItem {
    let name: String
    let path: String              // absolute path (dirPath + "/" + name)
    let isDirectory: Bool
    let sizeText: String          // "1.8 KB" / "—"
    let isoDate: String           // "2026-01-01"
    let agoText: String           // "5mo ago"
    let kindLabel: String         // "Folder" / "Code" / …
    let kindColor: NSColor
    let symbol: String            // SF Symbol name
    let symbolColor: NSColor      // category tint
    let extText: String           // "swift" / "—"
}

// MARK: - View controller

/// The app's centerpiece: a view-based NSTableView showing one index query
/// (the home-folder listing, depth 1). Replaces the placeholder. Columns and
/// row chrome follow the redesign spec §7 + the v2 prototype's browse mode.
final class BrowserViewController: NSViewController {
    private let coordinator: AppCoordinator
    private var items: [FileItem] = []

    private let scrollView = NSScrollView()
    private let tableView = ZestTableView()
    private var emptyLabel: NSTextField?

    // Derived accent family (dark) used by the selection chrome.
    fileprivate static let accent = Theme.deriveAccent(base: Theme.defaultAccentBase, theme: .dark)

    // Column identifiers.
    private static let colName = NSUserInterfaceItemIdentifier("name")
    private static let colSize = NSUserInterfaceItemIdentifier("size")
    private static let colMod  = NSUserInterfaceItemIdentifier("modified")
    private static let colKind = NSUserInterfaceItemIdentifier("kind")
    private static let colExt  = NSUserInterfaceItemIdentifier("ext")

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.background.cgColor
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildTable()
        buildEmptyState()
        tableView.target = self
        tableView.doubleAction = #selector(handleDoubleClick)
        reload()
    }

    // MARK: Data

    /// Re-run the coordinator's listing for the current folder, remap, and
    /// refresh the table (or empty state). Reselects row 0 when non-empty.
    func reload() {
        items = coordinator.currentListing().map { Self.makeItem(from: $0) }

        let isEmpty = items.isEmpty
        scrollView.isHidden = isEmpty
        emptyLabel?.isHidden = !isEmpty

        tableView.reloadData()
        if isEmpty {
            tableView.deselectAll(nil)
        } else {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
    }

    @objc private func handleDoubleClick() {
        let row = tableView.clickedRow
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        if item.isDirectory {
            coordinator.navigate(to: item.path)
        }
        // Files: no-op for now (opening files comes later).
    }

    private static func makeItem(from r: ZestCore.Row) -> FileItem {
        let isDir = r.kind == 1
        let meta = Category.meta(kind: r.kind, category: r.category)

        let sizeText = isDir ? "—" : byteFormatter.string(fromByteCount: Int64(bitPattern: r.size))

        let date = Date(timeIntervalSince1970: TimeInterval(r.mtime))
        let iso = isoFormatter.string(from: date)
        let ago = relativeText(from: r.mtime)

        let ext: String
        if isDir {
            ext = "—"
        } else if let dot = r.name.lastIndex(of: "."), dot != r.name.startIndex {
            let raw = r.name[r.name.index(after: dot)...]
            ext = raw.isEmpty ? "—" : raw.lowercased()
        } else {
            ext = "—"
        }

        let path = (r.dirPath as NSString).appendingPathComponent(r.name)

        return FileItem(
            name: r.name,
            path: path,
            isDirectory: isDir,
            sizeText: sizeText,
            isoDate: iso,
            agoText: ago,
            kindLabel: meta.label,
            kindColor: meta.color,
            symbol: meta.symbol,
            symbolColor: meta.color,
            extText: ext
        )
    }

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Relative bucket from a unix-seconds mtime: <1d "today", <30d "Nd ago",
    /// <365d "Nmo ago", else "Ny ago".
    private static func relativeText(from mtime: Int64) -> String {
        let now = Int64(Date().timeIntervalSince1970)
        let days = max(0, (now - mtime) / 86_400)
        if days < 1 { return "today" }
        if days < 30 { return "\(days)d ago" }
        if days < 365 { return "\(days / 30)mo ago" }
        return "\(days / 365)y ago"
    }

    // MARK: Empty state

    /// Build the empty-state label once; `reload()` toggles its visibility.
    /// Now means "this folder has no indexed entries" (which is fine).
    private func buildEmptyState() {
        guard emptyLabel == nil else { return }
        let label = NSTextField(labelWithString: "No indexed entries in this folder")
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = Theme.textSecondary
        label.alignment = .center
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        emptyLabel = label
    }

    // MARK: Table

    private func buildTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 34
        tableView.selectionHighlightStyle = .none
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.backgroundColor = Theme.background
        tableView.intercellSpacing = .zero
        tableView.gridStyleMask = []
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = false
        tableView.headerView = ZestTableHeaderView()
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        addColumn(Self.colName, "NAME", width: 360, min: 240, max: 100_000)
        addColumn(Self.colSize, "SIZE", width: 90, min: 90, max: 90, alignment: .right)
        addColumn(Self.colMod, "MODIFIED", width: 170, min: 170, max: 170)
        addColumn(Self.colKind, "KIND", width: 120, min: 120, max: 120)
        addColumn(Self.colExt, "EXT", width: 70, min: 70, max: 70)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.background
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.automaticallyAdjustsContentInsets = false
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func addColumn(
        _ id: NSUserInterfaceItemIdentifier, _ title: String,
        width: CGFloat, min: CGFloat, max: CGFloat,
        alignment: NSTextAlignment = .left
    ) {
        let col = NSTableColumn(identifier: id)
        col.width = width
        col.minWidth = min
        col.maxWidth = max
        col.title = title
        // Header drawing is handled by ZestTableHeaderCell; set the styled string too.
        col.headerCell = ZestHeaderCell(textCell: title)
        (col.headerCell as? ZestHeaderCell)?.alignment = alignment
        tableView.addTableColumn(col)
    }
}

// MARK: - Data source / delegate

extension BrowserViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("FileRowView")
        let v = (tableView.makeView(withIdentifier: id, owner: self) as? FileRowView) ?? {
            let r = FileRowView()
            r.identifier = id
            return r
        }()
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < items.count else { return nil }
        let item = items[row]
        let id = tableColumn.identifier

        switch id {
        case BrowserViewController.colName:
            let cell = dequeueName()
            cell.configure(item)
            return cell
        case BrowserViewController.colMod:
            let cell = dequeueLabel(id, alignment: .left, leading: 0, trailing: 12)
            cell.label.attributedStringValue = ModifiedCell.attributed(iso: item.isoDate, ago: item.agoText)
            return cell
        case BrowserViewController.colKind:
            let cell = dequeueKind()
            cell.configure(label: item.kindLabel, color: item.kindColor)
            return cell
        case BrowserViewController.colSize:
            let cell = dequeueLabel(id, alignment: .right, leading: 0, trailing: 10)
            cell.label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            cell.label.textColor = Theme.textSecondary
            cell.label.alignment = .right
            cell.label.stringValue = item.sizeText
            return cell
        case BrowserViewController.colExt:
            let cell = dequeueLabel(id, alignment: .left, leading: 0, trailing: 10)
            cell.label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            cell.label.textColor = Theme.textTertiary
            cell.label.alignment = .left
            cell.label.stringValue = item.extText
            return cell
        default:
            return nil
        }
    }

    private func dequeueName() -> NameCellView {
        let id = NSUserInterfaceItemIdentifier("NameCell")
        if let v = tableView.makeView(withIdentifier: id, owner: self) as? NameCellView { return v }
        let v = NameCellView()
        v.identifier = id
        return v
    }

    private func dequeueKind() -> KindCellView {
        let id = NSUserInterfaceItemIdentifier("KindCell")
        if let v = tableView.makeView(withIdentifier: id, owner: self) as? KindCellView { return v }
        let v = KindCellView()
        v.identifier = id
        return v
    }

    private func dequeueLabel(
        _ id: NSUserInterfaceItemIdentifier, alignment: NSTextAlignment,
        leading: CGFloat, trailing: CGFloat
    ) -> LabelCellView {
        if let v = tableView.makeView(withIdentifier: id, owner: self) as? LabelCellView { return v }
        let v = LabelCellView(leading: leading, trailing: trailing)
        v.identifier = id
        return v
    }
}

// MARK: - Table view (dark background through to the scroller corner)

private final class ZestTableView: NSTableView {
    override var isOpaque: Bool { true }
}

// MARK: - Row view: accent-soft fill + leading rail when selected

/// Selection chrome per spec §7: rounded `accentSoft` fill (inset 6h/2v, radius 6)
/// plus a 3pt `accent` rail on the leading edge. Drawn directly — super is not
/// called — and gated on `isSelected`.
final class FileRowView: NSTableRowView {
    override var isOpaque: Bool { false }

    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            // Re-weight the name label (semibold when selected).
            for sub in subviews { sub.needsLayout = true; sub.needsDisplay = true }
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        Theme.background.setFill()
        dirtyRect.fill()
        drawSelection(in: dirtyRect)
    }

    // The table uses `.none` selection style, so AppKit won't invoke this for us;
    // we call it from `drawBackground`. Draws the accent-soft fill + leading rail.
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let a = BrowserViewController.accent
        let fillRect = bounds.insetBy(dx: 6, dy: 2)
        let path = NSBezierPath(roundedRect: fillRect, xRadius: 6, yRadius: 6)
        a.accentSoft.setFill()
        path.fill()

        // 3pt rail on the leading edge.
        let rail = NSRect(x: 0, y: bounds.minY + 4, width: 3, height: bounds.height - 8)
        let railPath = NSBezierPath(roundedRect: rail, xRadius: 1.5, yRadius: 1.5)
        a.accent.setFill()
        railPath.fill()
    }
}

// MARK: - Header

/// Dark header strip behind the column titles.
private final class ZestTableHeaderView: NSTableHeaderView {
    override func draw(_ dirtyRect: NSRect) {
        Theme.background.setFill()
        bounds.fill()
        super.draw(dirtyRect)
    }
}

/// Uppercase, tracked, tertiary 11pt header cell on the dark strip.
private final class ZestHeaderCell: NSTableHeaderCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        Theme.background.setFill()
        cellFrame.fill()

        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Theme.textTertiary,
            .kern: 0.8,
            .paragraphStyle: style,
        ]
        let text = (stringValue as NSString)
        let inset: CGFloat = alignment == .right ? 0 : 14
        let rect = cellFrame.insetBy(dx: 0, dy: 0).offsetBy(dx: 0, dy: 5)
        let drawRect = NSRect(
            x: rect.minX + (alignment == .right ? 6 : inset),
            y: rect.minY,
            width: rect.width - inset - (alignment == .right ? 6 : 0),
            height: rect.height
        )
        text.draw(in: drawRect, withAttributes: attrs)
    }
}

// MARK: - Name cell (icon + label)

/// 18×18 SF Symbol tinted by category + a name label. Label weight bumps to
/// semibold when the row is selected.
final class NameCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(icon)
        addSubview(label)
        self.textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 11),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(_ item: FileItem) {
        let img = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.kindLabel)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        icon.image = img?.withSymbolConfiguration(config)
        icon.contentTintColor = item.symbolColor
        label.stringValue = item.name
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyWeight() }
    }

    private func applyWeight() {
        let selected = (superview as? FileRowView)?.isSelected ?? false
        label.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        applyWeight()
    }
}

// MARK: - Kind cell (dot + label)

/// 7×7 rounded dot in the category color + an 11.5pt label.
final class KindCellView: NSTableCellView {
    private let dot = DotView()
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        dot.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11.5, weight: .regular)
        label.textColor = Theme.textSecondary
        label.lineBreakMode = .byTruncatingTail

        addSubview(dot)
        addSubview(label)
        self.textField = label

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 7),
            dot.heightAnchor.constraint(equalToConstant: 7),

            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(label text: String, color: NSColor) {
        label.stringValue = text
        dot.color = color
        dot.needsDisplay = true
    }
}

/// A small rounded-rect color swatch.
final class DotView: NSView {
    var color: NSColor = .gray
    override var wantsUpdateLayer: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        color.setFill()
        p.fill()
    }
}

// MARK: - Modified cell (ISO date + dim relative)

/// Builds the two-color attributed string `2026-01-01 · 5mo ago`.
enum ModifiedCell {
    static func attributed(iso: String, ago: String) -> NSAttributedString {
        let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: iso, attributes: [
            .font: mono, .foregroundColor: Theme.textSecondary,
        ]))
        s.append(NSAttributedString(string: "  ·  \(ago)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: Theme.textTertiary,
        ]))
        return s
    }
}

// MARK: - Single-label cell used for Size / Modified / Ext columns

/// A vertically-centered label with explicit leading/trailing insets, laid out
/// with Auto Layout so right-aligned columns keep their breathing room.
final class LabelCellView: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init(leading: CGFloat, trailing: CGFloat) {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.textColor = Theme.textSecondary
        addSubview(label)
        self.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: leading),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -trailing),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}
