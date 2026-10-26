// Draws a small page through Quartz (the PDF writer used by Pages/Preview/Print).
import AppKit

let url = URL(fileURLWithPath: CommandLine.arguments[1])
var box = CGRect(x: 0, y: 0, width: 420, height: 200)
let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
ctx.beginPDFPage(nil)
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)

func text(_ s: String, _ font: String, _ size: CGFloat, _ p: CGPoint) {
    NSAttributedString(string: s, attributes: [.font: NSFont(name: font, size: size)!]).draw(at: p)
}
NSColor(red: 1, green: 0.93, blue: 0.67, alpha: 1).setFill()
CGRect(x: 20, y: 130, width: 180, height: 40).fill()
NSColor.black.setStroke()
let cells = NSBezierPath(rect: CGRect(x: 20, y: 130, width: 380, height: 40)); cells.stroke()
NSBezierPath.strokeLine(from: CGPoint(x: 200, y: 130), to: CGPoint(x: 200, y: 170))
text("Quarterly report", "Georgia", 14, CGPoint(x: 30, y: 142))
text("Total: 4,250", "Georgia-Bold", 14, CGPoint(x: 210, y: 142))
text("Prepared by the finance team", "AvenirNext-Regular", 12, CGPoint(x: 20, y: 90))
ctx.endPDFPage()
ctx.closePDF()
