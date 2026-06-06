import AppKit

/// File-category presentation metadata. Maps the index's category index (0–8)
/// to a display label, color, and SF Symbol. Mirrors the FileCategory enum order
/// in src/core/file_types.zig + the prototype's CAT map. A `kind == directory`
/// row overrides the category with `.folder`.
enum Category {
    struct Meta {
        let label: String
        let color: NSColor
        let symbol: String
    }

    // Indexed 0–8 by the index's category byte.
    static let byIndex: [Meta] = [
        Meta(label: "Other",       color: hex(0x86, 0x8E, 0x99), symbol: "doc"),                                       // 0 uncategorized
        Meta(label: "Image",       color: hex(0xE0, 0xA3, 0xFF), symbol: "photo"),                                     // 1 images
        Meta(label: "Text",        color: hex(0x9A, 0xA4, 0xB0), symbol: "doc.text"),                                  // 2 text
        Meta(label: "Document",    color: hex(0xC9, 0xA2, 0xFF), symbol: "doc.richtext"),                              // 3 documents
        Meta(label: "Spreadsheet", color: hex(0x3F, 0xC9, 0xA0), symbol: "tablecells"),                                // 4 spreadsheets
        Meta(label: "Audio",       color: hex(0xFF, 0x8C, 0xC8), symbol: "music.note"),                                // 5 audio
        Meta(label: "Video",       color: hex(0xFF, 0x7B, 0x72), symbol: "film"),                                      // 6 video
        Meta(label: "Code",        color: Theme.catCode,         symbol: "chevron.left.forwardslash.chevron.right"),   // 7 code
        Meta(label: "Archive",     color: hex(0x8C, 0x95, 0xA0), symbol: "archivebox"),                                // 8 archives
    ]

    static let folder = Meta(label: "Folder", color: Theme.catFolder, symbol: "folder")

    /// Presentation for a row. Directories (`kind == 1`) override the category.
    static func meta(kind: UInt8, category: UInt8) -> Meta {
        if kind == 1 { return folder }
        let i = Int(category)
        return (i >= 0 && i < byIndex.count) ? byIndex[i] : byIndex[0]
    }

    private static func hex(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}
