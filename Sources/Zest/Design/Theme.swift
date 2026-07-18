import AppKit

enum Appearance {
  case dark, light
}

/// Design tokens (Ink graphite base) + accent derivation. Mirrors the prototype:
/// one chosen hue (base); the effective accent is theme-shifted; the family is
/// derived from the effective accent. See spec §4.
enum Theme {
  // Ink neutrals (dark)
  static let background = srgb(0x0F, 0x11, 0x15)
  static let panel = srgb(0x16, 0x19, 0x1E)
  static let panel2 = srgb(0x1A, 0x1E, 0x23)
  static let panelElevated = srgb(0x1F, 0x24, 0x2A)
  static let hover = srgb(0x20, 0x25, 0x2B)
  /// Container-level hover wash (e.g. the whole address pill) — half-strength
  /// so per-element highlights (full `hover`) read on top of it.
  static let hoverDim = srgb(0x20, 0x25, 0x2B).withAlphaComponent(0.5)
  static let border = srgb(0x27, 0x2C, 0x33)
  static let text = srgb(0xE9, 0xEC, 0xEF)
  static let textSecondary = srgb(0x86, 0x8E, 0x99)
  static let textTertiary = srgb(0x56, 0x5E, 0x68)

  // Syntax colors. Kept semantic so grammar capture names can share one
  // hierarchy across JSON, Markdown, and Sema.
  static let syntaxKeyword = srgb(0xFF, 0x7B, 0x72)
  static let syntaxString = srgb(0xA5, 0xD6, 0xFF)
  static let syntaxComment = srgb(0x76, 0x83, 0x90)
  static let syntaxNumber = srgb(0xD2, 0xA8, 0xFF)
  static let syntaxConstant = srgb(0x79, 0xC0, 0xFF)
  static let syntaxFunction = srgb(0x7E, 0xE7, 0x87)
  static let syntaxPunctuation = srgb(0x8B, 0x94, 0x9E)
  static let syntaxOperator = srgb(0xFF, 0xA6, 0x57)
  static let syntaxVariable = srgb(0xE9, 0xEC, 0xEF)
  static let syntaxMarkupHeading = srgb(0xD2, 0xA8, 0xFF)
  static let syntaxMarkupReference = srgb(0x79, 0xC0, 0xFF)

  /// Dialog backdrop (--scrim).
  static let scrim = NSColor(srgbRed: 5 / 255, green: 7 / 255, blue: 10 / 255, alpha: 0.62)

  static let nearBlack = srgb(0x0C, 0x0E, 0x12)
  static let defaultAccentBase = srgb(0xB8, 0xFF, 0x3C)
  // lime

  // Category colors (theme-independent)
  static let catFolder = srgb(0x6E, 0x9B, 0xE0)
  static let catCode = srgb(0x46, 0xC2, 0x6A)
  static let catVideo = srgb(0xFF, 0x7B, 0x72)  // doubles as the destructive-hover red
  // … remaining categories added in a later phase …

  /// Letter-spacing for the 10.5pt uppercase section headers (sidebar
  /// PINNED/CATEGORIES, saved-filters SAVED FILTERS). One constant so the
  /// chrome tracks identically everywhere.
  static let sectionHeaderKern: CGFloat = 0.9

  /// The app currently ships dark-only; every view derives the same accent
  /// family. Compute it once instead of per-type statics.
  static let darkAccent = deriveAccent(base: defaultAccentBase, theme: .dark)

  struct Accent {
    let accent: NSColor
    // effective
    let accentHi: NSColor
    let accentSoft: NSColor
    let accentLine: NSColor
    let glow: NSColor
    let onAccent: NSColor
  }

  /// Effective accent + derived family for a chosen base hue and theme.
  static func deriveAccent(base: NSColor, theme: Appearance) -> Accent {
    let effective =
      (theme == .light)
      ? base.blended(withFraction: 0.42, of: .black) ?? base  // darken on light
      : base
    return Accent(
      accent: effective,
      accentHi: effective.blended(withFraction: 0.22, of: .white) ?? effective,
      accentSoft: effective.withAlphaComponent(0.13),
      accentLine: effective.withAlphaComponent(0.55),
      glow: effective.withAlphaComponent(0.16),
      onAccent: onAccent(forBase: base, theme: theme)
    )
  }

  static func onAccent(forBase base: NSColor, theme: Appearance) -> NSColor {
    if theme == .light {
      return .white
    }  // darkened effective accent
    return relativeLuminance(base) > 0.6 ? nearBlack : .white
  }

  static func relativeLuminance(_ color: NSColor) -> CGFloat {
    let c = color.usingColorSpace(.sRGB) ?? color
    return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
  }

  private static func srgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
  }
}
