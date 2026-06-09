import AppKit

/// File-category presentation metadata. Maps the index's category byte (0–8)
/// to a display label, color, and SF Symbol. Mirrors the FileCategory enum
/// in src/core/file_types.zig.
struct Category {
  let label: String
  let pluralLabel: String
  let color: NSColor
  let symbol: String
  var queryKey: String {
    pluralLabel.lowercased()
  }

  typealias Meta = Self

  /// Indexed by the index's category byte.
  static let all: [Category] = [
    .init("Other", "Other", 0x868E99, "doc"),
    .init("Image", "Images", 0xE0A3FF, "photo"),
    .init("Text", "Text", 0x9AA4B0, "doc.text"),
    .init("Document", "Documents", 0xC9A2FF, "doc.richtext"),
    .init("Spreadsheet", "Spreadsheets", 0x3FC9A0, "tablecells"),
    .init("Audio", "Audio", 0xFF8CC8, "music.note"),
    .init("Video", "Video", 0xFF7B72, "film"),
    .init("Code", "Code", Theme.catCode, "chevron.left.forwardslash.chevron.right"),
    .init("Archive", "Archives", 0x8C95A0, "archivebox"),
  ]

  static let folder = Category("Folder", "Folders", Theme.catFolder, "folder")

  /// Directories (`kind == 1`) override the category.
  static func meta(kind: UInt8, category: UInt8) -> Category {
    if kind == 1 { return folder }
    let i = Int(category)
    return i >= 0 && i < all.count ? all[i] : all[0]
  }

  static func meta(category index: Int) -> Category {
    index >= 0 && index < all.count ? all[index] : all[0]
  }

  private init(_ label: String, _ pluralLabel: String, _ color: NSColor, _ symbol: String) {
    self.label = label
    self.pluralLabel = pluralLabel
    self.color = color
    self.symbol = symbol
  }

  private init(_ label: String, _ pluralLabel: String, _ hex: Int, _ symbol: String) {
    self.label = label
    self.pluralLabel = pluralLabel
    color = NSColor(
      srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
      green: CGFloat((hex >> 8) & 0xFF) / 255,
      blue: CGFloat(hex & 0xFF) / 255,
      alpha: 1,
    )
    self.symbol = symbol
  }
}
