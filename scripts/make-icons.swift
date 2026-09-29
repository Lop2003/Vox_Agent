// Regenerates the app icons and in-app logo from Assets/Brand/VoxCode-logo.png (transparent PNG).
// Usage: swift scripts/make-icons.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
guard let source = NSBitmapImageRep(data: try Data(contentsOf: root.appendingPathComponent("Assets/Brand/VoxCode-logo.png"))),
      let full = source.cgImage else { fatalError("Can't read Assets/Brand/VoxCode-logo.png") }

// Crop to the visible pixels so the mark is centred by its shape, not by the canvas.
var minX = source.pixelsWide, minY = source.pixelsHigh, maxX = 0, maxY = 0
for y in stride(from: 0, to: source.pixelsHigh, by: 2) {
    for x in stride(from: 0, to: source.pixelsWide, by: 2) where source.colorAt(x: x, y: y)!.alphaComponent > 0.02 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
let mark = full.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!

/// Square PNG with the mark fitted into `fraction` of the side, on a dark gradient or transparent.
func render(_ side: Int, fraction: CGFloat, background: Bool) -> Data {
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(side)
    if background {
        let colors = [CGColor(srgbRed: 0.17, green: 0.17, blue: 0.19, alpha: 1), CGColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)]
        let gradient = CGGradient(colorsSpace: nil, colors: colors as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    }
    let scale = min(s * fraction / CGFloat(mark.width), s * fraction / CGFloat(mark.height))
    let w = CGFloat(mark.width) * scale, h = CGFloat(mark.height) * scale
    ctx.interpolationQuality = .high
    ctx.draw(mark, in: CGRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String) throws {
    try data.write(to: root.appendingPathComponent(path))
    print("wrote", path)
}

let icon = render(1024, fraction: 0.66, background: true) // opaque, full-bleed: iOS and macOS mask the corners
try write(icon, "Assets/Brand/AppIcon-1024.png")
try write(icon, "VoxCodeMobile/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
try write(render(512, fraction: 1, background: false), "Sources/VoxUI/Resources/Logo.png")
