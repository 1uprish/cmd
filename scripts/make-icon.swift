import Cocoa
import CoreText
import CoreGraphics

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }

    // 1. Background — dark rounded rect
    let radius = size * 0.224  // Apple standard ~22.4%
    let bgColor = CGColor(red: 0.08, green: 0.08, blue: 0.10, alpha: 1)
    ctx.setFillColor(bgColor)
    let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                        cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(bgPath)
    ctx.fillPath()

    // 2. Subtle inner border (like macOS app icons)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
    ctx.setLineWidth(size * 0.004)
    ctx.addPath(CGPath(roundedRect: CGRect(x: size*0.004, y: size*0.004,
                                           width: size*0.992, height: size*0.992),
                        cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.strokePath()

    // 3. Draw ⌘ using CTLine — measure VISUAL (ink) bounds, not typographic
    let targetFill = 0.52  // glyph should fill 52% of icon width
    var fontSize = size * targetFill

    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .thin),
        .foregroundColor: NSColor.white
    ]
    var attrStr = NSAttributedString(string: "⌘", attributes: attrs)
    var line = CTLineCreateWithAttributedString(attrStr)

    // Binary search for font size that hits the target width
    var lo = size * 0.2, hi = size * 0.9
    for _ in 0..<20 {
        fontSize = (lo + hi) / 2
        let a: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .thin),
            .foregroundColor: NSColor.white
        ]
        attrStr = NSAttributedString(string: "⌘", attributes: a)
        line = CTLineCreateWithAttributedString(attrStr)
        let imgBounds = CTLineGetImageBounds(line, ctx)  // VISUAL bounds
        if imgBounds.width < size * targetFill { lo = fontSize } else { hi = fontSize }
    }

    // Get final visual bounds
    let imgBounds = CTLineGetImageBounds(line, ctx)

    // Center based on VISUAL bounds (not typographic)
    // CTLineGetImageBounds origin is relative to the text drawing origin (0,0)
    // We need to offset so the ink rect is centered on the canvas
    let drawX = (size - imgBounds.width) / 2 - imgBounds.origin.x
    let drawY = (size - imgBounds.height) / 2 - imgBounds.origin.y

    ctx.textMatrix = CGAffineTransform.identity
    ctx.textPosition = CGPoint(x: drawX, y: drawY)
    CTLineDraw(line, ctx)

    // Report visual bounds at 1024px for verification
    if size == 1024 {
        fputs("  [1024px] imgBounds.origin = (\(imgBounds.origin.x), \(imgBounds.origin.y)), size = \(imgBounds.width) x \(imgBounds.height)\n", stderr)
    }

    return image
}

// Export all sizes
let sizes: [(Int, String)] = [
    (16,  "icon_16x16"),    (32,  "icon_16x16@2x"),
    (32,  "icon_32x32"),    (64,  "icon_32x32@2x"),
    (128, "icon_128x128"),  (256, "icon_128x128@2x"),
    (256, "icon_256x256"),  (512, "icon_256x256@2x"),
    (512, "icon_512x512"),  (1024,"icon_512x512@2x"),
]

let iconsetDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

for (px, name) in sizes {
    let img = renderIcon(size: CGFloat(px))
    if let tiff = img.tiffRepresentation,
       let bmp = NSBitmapImageRep(data: tiff),
       let png = bmp.representation(using: .png, properties: [:]) {
        let url = iconsetDir.appendingPathComponent("\(name).png")
        try? png.write(to: url)
        print("  ✓ \(name).png (\(px)px)")
    }
}
print("Done.")
