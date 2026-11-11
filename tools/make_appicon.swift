import AppKit

// Draws the app icon and writes an .iconset directory.
// usage: swift tools/make_appicon.swift <output.iconset>

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"

func render(_ size: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let inset = size * 0.08
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = (size - inset * 2) * 0.22

    let background = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.22, blue: 0.30, alpha: 1.0),
        NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.14, alpha: 1.0),
    ])
    gradient?.draw(in: background, angle: -90)

    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.52, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.96),
        .paragraphStyle: paragraph,
    ]
    let text = NSAttributedString(string: "文", attributes: attributes)
    let textSize = text.size()
    text.draw(in: NSRect(
        x: 0,
        y: (size - textSize.height) / 2 - size * 0.015,
        width: size,
        height: textSize.height
    ))

    // A small accent dot: "context".
    let dot = NSBezierPath(ovalIn: NSRect(x: size * 0.68, y: size * 0.68, width: size * 0.1, height: size * 0.1))
    NSColor(calibratedRed: 0.36, green: 0.78, blue: 0.65, alpha: 1.0).setFill()
    dot.fill()

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
        FileHandle.standardError.write(Data("could not render icon\n".utf8))
        exit(1)
    }
    return png
}

let fileManager = FileManager.default
try? fileManager.createDirectory(atPath: output, withIntermediateDirectories: true)

let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for variant in variants {
    let data = render(variant.size)
    try! data.write(to: URL(fileURLWithPath: output).appendingPathComponent(variant.name))
}
print("wrote \(output)")
