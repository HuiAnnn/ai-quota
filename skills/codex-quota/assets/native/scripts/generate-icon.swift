import AppKit
import Foundation

// AppKit draws every icon size directly, keeping the bundle entirely local.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: swift generate-icon.swift <AppIcon.iconset>\n", stderr)
    exit(1)
}

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

func drawIcon(size: Int, filename: String) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "CodexQuota.Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建图标绘图上下文"])
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.shouldAntialias = true
    let scale = CGFloat(size) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)

    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 198, yRadius: 198)
    let gradient = NSGradient(
        starting: NSColor(srgbRed: 0.16, green: 0.23, blue: 0.29, alpha: 1),
        ending: NSColor(srgbRed: 0.045, green: 0.09, blue: 0.13, alpha: 1)
    )!
    gradient.draw(in: tile, angle: -70)

    // A progress ring communicates remaining quota without borrowing a logo.
    let center = NSPoint(x: 512, y: 512)
    let track = NSBezierPath(ovalIn: NSRect(x: 256, y: 256, width: 512, height: 512))
    track.lineWidth = 72
    NSColor(srgbRed: 0.28, green: 0.38, blue: 0.43, alpha: 1).setStroke()
    track.stroke()

    let progress = NSBezierPath()
    progress.appendArc(withCenter: center, radius: 256, startAngle: 90, endAngle: -182, clockwise: true)
    progress.lineWidth = 72
    progress.lineCapStyle = .round
    NSColor(srgbRed: 0.47, green: 0.94, blue: 0.77, alpha: 1).setStroke()
    progress.stroke()

    let clock = NSBezierPath()
    clock.move(to: NSPoint(x: 512, y: 638))
    clock.line(to: center)
    clock.line(to: NSPoint(x: 611, y: 449))
    clock.lineWidth = 54
    clock.lineCapStyle = .round
    clock.lineJoinStyle = .round
    NSColor.white.setStroke()
    clock.stroke()

    NSGraphicsContext.restoreGraphicsState()
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CodexQuota.Icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法编码 PNG 图标"])
    }
    try png.write(to: destination.appendingPathComponent(filename), options: .atomic)
}

for baseSize in [16, 32, 128, 256, 512] {
    try drawIcon(size: baseSize, filename: "icon_\(baseSize)x\(baseSize).png")
    try drawIcon(size: baseSize * 2, filename: "icon_\(baseSize)x\(baseSize)@2x.png")
}
