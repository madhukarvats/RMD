// Draws RMD's app icon (a white waveform on a blue tile) into RMD/Assets.xcassets/AppIcon.appiconset.
// Run from the project folder: swift tools/make-icon.swift
import AppKit

let folder = URL(filePath: "RMD/Assets.xcassets/AppIcon.appiconset", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func png(pixels: Int) throws -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(pixels) / 1024
    // macOS icon grid: an 824 pt rounded tile centred on a 1024 pt canvas.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale),
                            xRadius: 185 * scale, yRadius: 185 * scale)
    NSGradient(starting: NSColor(srgbRed: 0.36, green: 0.30, blue: 0.96, alpha: 1),
               ending: NSColor(srgbRed: 0.09, green: 0.56, blue: 0.98, alpha: 1))!.draw(in: tile, angle: -60)
    let config = NSImage.SymbolConfiguration(pointSize: 400 * scale, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    symbol.draw(in: NSRect(x: (CGFloat(pixels) - symbol.size.width) / 2, y: (CGFloat(pixels) - symbol.size.height) / 2,
                           width: symbol.size.width, height: symbol.size.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(pixels: points * scale).write(to: folder.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: folder.appending(path: "Contents.json"))
try #"{ "info" : { "author" : "xcode", "version" : 1 } }"#.write(
    to: folder.deletingLastPathComponent().appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(images.count) icon sizes to \(folder.path)")
