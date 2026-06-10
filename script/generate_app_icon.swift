import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root
    .appendingPathComponent("Resources", isDirectory: true)
    .appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(name: String, points: CGFloat, scale: CGFloat)] = [
    ("icon_16x16.png", 16, 1),
    ("icon_16x16@2x.png", 16, 2),
    ("icon_32x32.png", 32, 1),
    ("icon_32x32@2x.png", 32, 2),
    ("icon_128x128.png", 128, 1),
    ("icon_128x128@2x.png", 128, 2),
    ("icon_256x256.png", 256, 1),
    ("icon_256x256@2x.png", 256, 2),
    ("icon_512x512.png", 512, 1),
    ("icon_512x512@2x.png", 512, 2)
]

for size in sizes {
    let pixels = Int(size.points * size.scale)
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    drawIcon(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Could not render \(size.name)")
    }

    try data.write(to: iconset.appendingPathComponent(size.name))
}

func drawIcon(in rect: NSRect) {
    NSGraphicsContext.current?.imageInterpolation = .high

    let radius = rect.width * 0.22
    let background = NSBezierPath(roundedRect: rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.04), xRadius: radius, yRadius: radius)
    NSColor(calibratedRed: 0.08, green: 0.10, blue: 0.12, alpha: 1).setFill()
    background.fill()

    let inner = rect.insetBy(dx: rect.width * 0.11, dy: rect.height * 0.11)
    let panel = NSBezierPath(roundedRect: inner, xRadius: rect.width * 0.16, yRadius: rect.width * 0.16)
    NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.20, alpha: 1).setFill()
    panel.fill()

    let drive = NSRect(
        x: rect.width * 0.20,
        y: rect.height * 0.28,
        width: rect.width * 0.60,
        height: rect.height * 0.38
    )
    let body = NSBezierPath(roundedRect: drive, xRadius: rect.width * 0.08, yRadius: rect.width * 0.08)
    NSColor(calibratedRed: 0.20, green: 0.45, blue: 0.95, alpha: 1).setFill()
    body.fill()

    let cap = NSRect(
        x: drive.minX + drive.width * 0.12,
        y: drive.maxY - drive.height * 0.08,
        width: drive.width * 0.76,
        height: drive.height * 0.24
    )
    let capPath = NSBezierPath(roundedRect: cap, xRadius: rect.width * 0.05, yRadius: rect.width * 0.05)
    NSColor(calibratedRed: 0.27, green: 0.58, blue: 1.00, alpha: 1).setFill()
    capPath.fill()

    let barCount = 5
    let barWidth = rect.width * 0.035
    let barHeight = rect.height * 0.13
    let spacing = rect.width * 0.035
    let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
    let startX = rect.midX - totalWidth / 2
    for index in 0..<barCount {
        let x = startX + CGFloat(index) * (barWidth + spacing)
        let bar = NSBezierPath(roundedRect: NSRect(x: x, y: drive.minY + drive.height * 0.19, width: barWidth, height: barHeight), xRadius: barWidth / 2, yRadius: barWidth / 2)
        NSColor(calibratedRed: 0.03, green: 0.08, blue: 0.15, alpha: 0.72).setFill()
        bar.fill()
    }

    let lensRect = NSRect(
        x: rect.width * 0.58,
        y: rect.height * 0.58,
        width: rect.width * 0.22,
        height: rect.width * 0.22
    )
    let lens = NSBezierPath(ovalIn: lensRect)
    NSColor(calibratedRed: 0.35, green: 0.95, blue: 0.70, alpha: 1).setStroke()
    lens.lineWidth = max(2, rect.width * 0.026)
    lens.stroke()

    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: lensRect.maxX - rect.width * 0.03, y: lensRect.minY + rect.height * 0.03))
    handle.line(to: NSPoint(x: lensRect.maxX + rect.width * 0.10, y: lensRect.minY - rect.height * 0.10))
    handle.lineCapStyle = .round
    handle.lineWidth = max(2, rect.width * 0.032)
    NSColor(calibratedRed: 0.65, green: 0.45, blue: 1.00, alpha: 1).setStroke()
    handle.stroke()
}
