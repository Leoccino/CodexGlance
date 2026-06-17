import AppKit
import Foundation

func drawIcon(size: CGFloat, outputURL: URL) throws {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    bounds.fill()

    let cornerRadius = size * 0.22
    let background = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.11, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.20, alpha: 1)
    ])
    gradient?.draw(in: background, angle: 315)

    let inset = size * 0.15
    let panel = NSRect(x: inset, y: size * 0.19, width: size - inset * 2, height: size * 0.62)
    let panelPath = NSBezierPath(roundedRect: panel, xRadius: size * 0.09, yRadius: size * 0.09)
    NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
    panelPath.fill()

    NSColor(calibratedRed: 0.43, green: 0.95, blue: 0.67, alpha: 1).setFill()
    let dotSize = size * 0.08
    NSBezierPath(ovalIn: NSRect(x: panel.minX + size * 0.08, y: panel.maxY - size * 0.15, width: dotSize, height: dotSize)).fill()

    let font = NSFont.monospacedSystemFont(ofSize: size * 0.15, weight: .bold)
    let labelAttributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.92)
    ]
    ("5h" as NSString).draw(
        at: NSPoint(x: panel.minX + size * 0.19, y: panel.maxY - size * 0.18),
        withAttributes: labelAttributes
    )

    let barY = panel.minY + size * 0.17
    let barX = panel.minX + size * 0.08
    let gap = size * 0.025
    let segmentWidth = (panel.width - size * 0.16 - gap * 4) / 5
    let segmentHeight = size * 0.13

    for index in 0..<5 {
        let rect = NSRect(
            x: barX + CGFloat(index) * (segmentWidth + gap),
            y: barY,
            width: segmentWidth,
            height: segmentHeight
        )
        let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.025, yRadius: size * 0.025)
        if index < 4 {
            NSColor(calibratedRed: 0.43, green: 0.95, blue: 0.67, alpha: 1).setFill()
        } else {
            NSColor(calibratedWhite: 1, alpha: 0.22).setFill()
        }
        path.fill()
    }

    let shine = NSBezierPath()
    shine.move(to: NSPoint(x: size * 0.22, y: size * 0.84))
    shine.line(to: NSPoint(x: size * 0.78, y: size * 0.84))
    shine.lineWidth = size * 0.015
    NSColor(calibratedWhite: 1, alpha: 0.20).setStroke()
    shine.stroke()

    image.unlockFocus()

    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to render PNG"])
    }

    try png.write(to: outputURL)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fputs("usage: IconGenerator <iconset-output-dir>\n", stderr)
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

try drawIcon(size: 1024, outputURL: outputDirectory.appendingPathComponent("CodexGlanceIcon.png"))
