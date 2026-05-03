#!/usr/bin/env swift
import AppKit

let outputPath = CommandLine.arguments.dropFirst().first ?? "build/dmg-background.png"
let size = NSSize(width: 720, height: 460)

let image = NSImage(size: size)
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("Could not create graphics context")
}

func color(_ white: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedWhite: white, alpha: alpha)
}

let rect = NSRect(origin: .zero, size: size)
NSColor(calibratedRed: 0.045, green: 0.047, blue: 0.052, alpha: 1).setFill()
rect.fill()

let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1),
    NSColor(calibratedRed: 0.045, green: 0.047, blue: 0.052, alpha: 1),
    NSColor(calibratedRed: 0.08, green: 0.085, blue: 0.095, alpha: 1),
])!
gradient.draw(in: rect, angle: -18)

let vignette = NSGradient(colors: [
    NSColor(calibratedWhite: 0, alpha: 0.0),
    NSColor(calibratedWhite: 0, alpha: 0.42),
])!
vignette.draw(in: rect.insetBy(dx: -180, dy: -140), relativeCenterPosition: NSPoint(x: 0, y: -0.06))

let panel = NSBezierPath(roundedRect: NSRect(x: 42, y: 44, width: 636, height: 372), xRadius: 34, yRadius: 34)
NSColor(calibratedWhite: 1, alpha: 0.045).setFill()
panel.fill()
NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
panel.lineWidth = 1
panel.stroke()

let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1),
    .kern: 0
]
"Install cmd".draw(
    in: NSRect(x: 0, y: 362, width: size.width, height: 40),
    withAttributes: titleAttrs.aligned(.center)
)

let subtitleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.78, alpha: 0.92),
    .kern: 0
]
"Drag the app into Applications".draw(
    in: NSRect(x: 0, y: 334, width: size.width, height: 24),
    withAttributes: subtitleAttrs.aligned(.center)
)

let leftHalo = NSBezierPath(ovalIn: NSRect(x: 110, y: 142, width: 150, height: 150))
NSColor(calibratedWhite: 1, alpha: 0.045).setFill()
leftHalo.fill()

let rightHalo = NSBezierPath(ovalIn: NSRect(x: 460, y: 142, width: 150, height: 150))
NSColor(calibratedWhite: 1, alpha: 0.04).setFill()
rightHalo.fill()

let path = NSBezierPath()
path.move(to: NSPoint(x: 282, y: 220))
path.curve(
    to: NSPoint(x: 438, y: 220),
    controlPoint1: NSPoint(x: 330, y: 258),
    controlPoint2: NSPoint(x: 390, y: 258)
)

for offset in stride(from: 10, through: 1, by: -1) {
    let glow = path.copy() as! NSBezierPath
    glow.lineWidth = CGFloat(offset) * 1.5
    NSColor(calibratedRed: 0.48, green: 0.62, blue: 1.0, alpha: 0.018).setStroke()
    glow.stroke()
}

path.lineWidth = 3
NSColor(calibratedWhite: 0.92, alpha: 0.62).setStroke()
path.stroke()

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 438, y: 220))
arrow.line(to: NSPoint(x: 420, y: 232))
arrow.move(to: NSPoint(x: 438, y: 220))
arrow.line(to: NSPoint(x: 420, y: 208))
arrow.lineWidth = 3
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(calibratedWhite: 0.92, alpha: 0.62).setStroke()
arrow.stroke()

let hintAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 0.88),
]
"one clean move".draw(
    in: NSRect(x: 292, y: 174, width: 136, height: 20),
    withAttributes: hintAttrs.aligned(.center)
)

let footerAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.58, alpha: 0.82),
]
"Then open cmd from Applications and grant Accessibility when prompted.".draw(
    in: NSRect(x: 0, y: 72, width: size.width, height: 18),
    withAttributes: footerAttrs.aligned(.center)
)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Could not render PNG")
}

let url = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
try png.write(to: url, options: .atomic)

private extension Dictionary where Key == NSAttributedString.Key, Value == Any {
    func aligned(_ alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
        var copy = self
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        copy[.paragraphStyle] = paragraph
        return copy
    }
}
