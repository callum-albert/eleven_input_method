import AppKit
import CoreGraphics

// Generates menu_icon.pdf: a template image (black + alpha) used by the
// input-source menu. usage: swift tools/make_icon.swift <output.pdf>

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "menu_icon.pdf"
let size = 64.0

let data = NSMutableData()
var mediaBox = CGRect(x: 0, y: 0, width: size, height: size)
guard let consumer = CGDataConsumer(data: data as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
    FileHandle.standardError.write(Data("cannot create PDF context\n".utf8))
    exit(1)
}

context.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 50, weight: .medium),
    .foregroundColor: NSColor.black,
    .paragraphStyle: paragraph,
]
let string = NSAttributedString(string: "文", attributes: attributes)
let textSize = string.size()
string.draw(in: NSRect(x: 0, y: (size - textSize.height) / 2 + 2, width: size, height: textSize.height))

NSGraphicsContext.restoreGraphicsState()
context.endPDFPage()
context.closePDF()

try! (data as Data).write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
