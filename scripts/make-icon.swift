// Draws the app icon and writes AppIcon.icns into the directory given as the first argument.
// Usage: swift scripts/make-icon.swift build
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// `fullBleed` draws the body almost edge to edge, the way Windows icons look.
func drawIcon(size: CGFloat, fullBleed: Bool = false) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // macOS icon grid: 824×824 body centred in a 1024 canvas.
    let inset: CGFloat = fullBleed ? 40 : 100
    let body = NSRect(x: inset * s, y: inset * s, width: (1024 - 2 * inset) * s, height: (1024 - 2 * inset) * s)
    let radius: CGFloat = fullBleed ? 210 : 185
    let path = NSBezierPath(roundedRect: body, xRadius: radius * s, yRadius: radius * s)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(fullBleed ? 0 : 0.28)
    shadow.shadowBlurRadius = 28 * s
    shadow.shadowOffset = NSSize(width: 0, height: -12 * s)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.16, green: 0.50, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.45, green: 0.36, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.93, green: 0.40, blue: 0.72, alpha: 1),
    ])!
    gradient.draw(in: path, angle: -50)

    // Soft highlight on the top half.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let highlight = NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
    highlight.draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let config = NSImage.SymbolConfiguration(pointSize: 360 * s, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "display.2", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        let rect = NSRect(x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2 + 20 * s,
                          width: symbolSize.width, height: symbolSize.height)
        symbol.draw(in: rect)
    }

    let arrowsConfig = NSImage.SymbolConfiguration(pointSize: 150 * s, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor.white.withAlphaComponent(0.9)]))
    if let arrows = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil)?.withSymbolConfiguration(arrowsConfig) {
        let a = arrows.size
        arrows.draw(in: NSRect(x: (size - a.width) / 2, y: 175 * s, width: a.width, height: a.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(String, CGFloat)] = [
    ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
    ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
    ("512x512", 512), ("512x512@2x", 1024),
]
for (name, size) in sizes {
    let data = drawIcon(size: size).representation(using: .png, properties: [:])!
    try data.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", outDir.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

// Windows .ico: PNG-compressed entries (supported since Windows Vista).
let icoSizes: [CGFloat] = [16, 20, 24, 32, 40, 48, 64, 128, 256]
let pngs = icoSizes.map { drawIcon(size: $0, fullBleed: true).representation(using: .png, properties: [:])! }
var ico = Data([0, 0, 1, 0, UInt8(icoSizes.count & 0xFF), UInt8(icoSizes.count >> 8)])
var offset = 6 + 16 * icoSizes.count
for (size, png) in zip(icoSizes, pngs) {
    let side = UInt8(size >= 256 ? 0 : Int(size))
    ico.append(contentsOf: [side, side, 0, 0, 1, 0, 32, 0])
    withUnsafeBytes(of: UInt32(png.count).littleEndian) { ico.append(contentsOf: $0) }
    withUnsafeBytes(of: UInt32(offset).littleEndian) { ico.append(contentsOf: $0) }
    offset += png.count
}
for png in pngs { ico.append(png) }
try ico.write(to: outDir.appendingPathComponent("AppIcon.ico"))
print("AppIcon.icns and AppIcon.ico written to \(outDir.path)")
