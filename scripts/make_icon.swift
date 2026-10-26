import AppKit
import ImageIO
import UniformTypeIdentifiers

// Draws the app icon in the Uberdoer style: a dark navy squircle with a blue
// rim glow, a stack of glossy blue pages and a cyan-to-green "T".
// Usage: swift scripts/make_icon.swift <out.iconset>

let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// A portrait page with a dog-eared top-right corner, centred on the origin.
func pagePath(width: CGFloat, height: CGFloat, radius: CGFloat, fold: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let l = -width / 2, r = width / 2, b = -height / 2, t = height / 2
    p.move(to: CGPoint(x: l + radius, y: b))
    p.addArc(tangent1End: CGPoint(x: r, y: b), tangent2End: CGPoint(x: r, y: t), radius: radius)
    p.addLine(to: CGPoint(x: r, y: t - fold))
    p.addLine(to: CGPoint(x: r - fold, y: t))
    p.addArc(tangent1End: CGPoint(x: l, y: t), tangent2End: CGPoint(x: l, y: b), radius: radius)
    p.addArc(tangent1End: CGPoint(x: l, y: b), tangent2End: CGPoint(x: r, y: b), radius: radius)
    p.closeSubpath()
    return p
}

func fill(_ ctx: CGContext, _ path: CGPath, _ g: CGGradient, from: CGPoint, to: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext) {
    // Squircle background with the Apple macOS icon grid proportions (824 of 1024).
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: tile, cornerWidth: 184, cornerHeight: 184, transform: nil)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.drawRadialGradient(gradient([rgb(0x13244D), rgb(0x070D1F)]),
                           startCenter: CGPoint(x: 512, y: 640), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 512), endRadius: 600, options: .drawsAfterEndLocation)
    // Blue glow just inside the rim.
    ctx.setShadow(offset: .zero, blur: 40, color: rgb(0x2F7BFF, 0.9))
    ctx.setStrokeColor(rgb(0x2F7BFF, 0.45))
    ctx.setLineWidth(7)
    ctx.addPath(squircle)
    ctx.strokePath()
    ctx.restoreGState()

    let w: CGFloat = 400, h: CGFloat = 510, radius: CGFloat = 44, fold: CGFloat = 100
    let page = pagePath(width: w, height: h, radius: radius, fold: fold)
    let depth: CGFloat = 16

    // Back pages first, each shifted right and down, getting deeper and more violet.
    let layers: [(dx: CGFloat, dy: CGFloat, top: UInt32, bottom: UInt32, edge: UInt32)] = [
        (96, -78, 0x3B4BE6, 0x3A2FC4, 0x241C8A),
        (48, -39, 0x2F78F2, 0x3046D6, 0x1E2FA0),
        (0, 0, 0x4FC2FF, 0x2B62F2, 0x1C3DB8),
    ]
    for (i, layer) in layers.enumerated() {
        ctx.saveGState()
        ctx.translateBy(x: 470 + layer.dx, y: 548 + layer.dy)
        ctx.rotate(by: 5 * .pi / 180)

        // Thickness: a darker copy below the face, with a soft blue glow.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 36, color: rgb(0x1F5BFF, 0.55))
        ctx.translateBy(x: 0, y: -depth)
        ctx.addPath(page)
        ctx.setFillColor(rgb(layer.edge))
        ctx.fillPath()
        ctx.restoreGState()

        fill(ctx, page, gradient([rgb(layer.top), rgb(layer.bottom)]),
             from: CGPoint(x: -w / 2, y: h / 2), to: CGPoint(x: w / 2, y: -h / 2))
        // Gloss on the upper half and a bright top edge.
        fill(ctx, page, gradient([rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)]),
             from: CGPoint(x: 0, y: h / 2), to: CGPoint(x: 0, y: 0))
        ctx.addPath(page)
        ctx.setStrokeColor(rgb(0xBFE6FF, i == 2 ? 0.55 : 0.3))
        ctx.setLineWidth(3)
        ctx.strokePath()

        // The dog-ear: a lighter triangle folded down over the corner.
        let ear = CGMutablePath()
        ear.move(to: CGPoint(x: w / 2 - fold, y: h / 2))
        ear.addLine(to: CGPoint(x: w / 2 - fold + 12, y: h / 2 - fold + 12))
        ear.addQuadCurve(to: CGPoint(x: w / 2, y: h / 2 - fold), control: CGPoint(x: w / 2 - fold + 10, y: h / 2 - fold))
        ear.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: -6, height: -8), blur: 14, color: rgb(0x0A1A60, 0.6))
        fill(ctx, ear, gradient([rgb(0xD8F3FF), rgb(0x7FC8FF)]),
             from: CGPoint(x: w / 2 - fold, y: h / 2 - fold), to: CGPoint(x: w / 2, y: h / 2))
        ctx.restoreGState()

        if i == 2 { drawText(ctx, width: w, height: h) }
        ctx.restoreGState()
    }
}

/// The front page's content: a glossy extruded "T" and two lines of text.
func drawText(_ ctx: CGContext, width w: CGFloat, height h: CGFloat) {
    // Faint lines of text under the glyph.
    for (y, len) in [(-150.0, 250.0), (-196.0, 180.0)] as [(CGFloat, CGFloat)] {
        let bar = CGPath(roundedRect: CGRect(x: -w / 2 + 70, y: y, width: len, height: 22),
                         cornerWidth: 11, cornerHeight: 11, transform: nil)
        ctx.addPath(bar)
        ctx.setFillColor(rgb(0xDDF2FF, 0.4))
        ctx.fillPath()
    }

    let t = CGMutablePath()
    t.addRoundedRect(in: CGRect(x: -125, y: 92, width: 250, height: 72), cornerWidth: 36, cornerHeight: 36)
    t.addRoundedRect(in: CGRect(x: -36, y: -100, width: 72, height: 250), cornerWidth: 36, cornerHeight: 36)
    let glyph = t.normalized()
    let extrude: CGFloat = 14

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x0A1F8A, 0.7))
    ctx.translateBy(x: 0, y: -extrude)
    ctx.addPath(glyph)
    ctx.setFillColor(rgb(0x1E56E0))
    ctx.fillPath()
    ctx.restoreGState()

    fill(ctx, glyph, gradient([rgb(0x9CF5D6), rgb(0x5FE0FF), rgb(0x4AA8FF)], [0, 0.45, 1]),
         from: CGPoint(x: 120, y: 170), to: CGPoint(x: -60, y: -100))
    fill(ctx, glyph, gradient([rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0)]),
         from: CGPoint(x: 0, y: 164), to: CGPoint(x: 0, y: 110))
    ctx.addPath(glyph)
    ctx.setStrokeColor(rgb(0xE8FFFF, 0.6))
    ctx.setLineWidth(3)
    ctx.strokePath()
}

func render(_ px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    drawIcon(ctx)
    return ctx.makeImage()!
}

func write(_ image: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: out).appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

for base in [16, 32, 128, 256, 512] {
    write(render(base), "icon_\(base)x\(base).png")
    write(render(base * 2), "icon_\(base)x\(base)@2x.png")
}
