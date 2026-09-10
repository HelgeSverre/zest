// Deterministic native vector artwork for the release icon; no external assets.
import AppKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let pixels = size * scale
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let factor = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: factor)
    transform.concat()
    NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 205, yRadius: 205).fill()
    NSColor(calibratedRed: 0.57, green: 0.74, blue: 0.35, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 205, y: 330, width: 614, height: 374), xRadius: 65, yRadius: 65).fill()
    NSBezierPath(roundedRect: NSRect(x: 205, y: 610, width: 272, height: 135), xRadius: 40, yRadius: 40).fill()
    NSColor(calibratedRed: 0.72, green: 0.94, blue: 0.44, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 205, y: 290, width: 614, height: 330), xRadius: 65, yRadius: 65).fill()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = bitmap.representation(using: .png, properties: [:])!
    let suffix = scale == 2 ? "@2x" : ""
    try data.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
  }
}
