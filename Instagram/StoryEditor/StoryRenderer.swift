import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation

/// Draws the story's layers. The editor shows rasters made here (a text item, the drawing)
/// and the export draws the same things at full size, so what you see is what's posted.
/// Contexts passed in are y-down (top-left origin) in canvas units; `ppu` is pixels per unit
/// (shadow blur is in pixels, so it's scaled by hand).
nonisolated enum StoryRenderer {
    static let canvas = StoryDoc.size
    /// Text wraps at this width (units).
    static let textWrap: CGFloat = 880
    static let stickerSize: CGFloat = 190
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Fonts

    static func font(_ style: StoryTextStyle) -> CTFont {
        for name in style.fontNames {
            let f = CTFontCreateWithName(name as CFString, style.size, nil)
            if (CTFontCopyPostScriptName(f) as String) == name { return f }
        }
        return CTFontCreateUIFontForLanguage(.emphasizedSystem, style.size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, style.size, nil)
    }

    static func emojiFont() -> CTFont { CTFontCreateWithName("AppleColorEmoji" as CFString, stickerSize, nil) }

    // MARK: Text layout

    /// A laid-out text item: its box (units, padding included) and, in the box's y-up
    /// coordinates, the frame and each line's highlight rectangle.
    struct Layout {
        var size: CGSize
        /// Room around the visible piece (for a glow) that isn't part of it: hit testing and
        /// the selection frame use the box inset by this much on each side.
        var inset: CGFloat
        var frame: CTFrame
        var lineRects: [CGRect]
        var fontSize: CGFloat
    }

    /// The text colour after the highlight is taken into account.
    static func foreground(_ t: StoryText) -> StoryColor {
        switch t.highlight {
        case .none: t.style == .neon ? t.color.lighter(0.7) : t.color
        case .solid, .translucent: t.color.contrasting
        }
    }

    static func layout(_ kind: StoryItem.Kind) -> Layout? {
        switch kind {
        case .text(let t):
            let s = t.style.uppercased ? t.string.uppercased() : t.string
            return layout(s, font: font(t.style), color: foreground(t), alignment: t.alignment, lineSpacing: t.style == .neon ? -0.1 : 0,
                          pad: 0.5, visible: 0.3)
        case .sticker(let e):
            return layout(e, font: emojiFont(), color: .white, alignment: .center, lineSpacing: 0, pad: 0.1, visible: 0.05)
        }
    }

    /// `pad` and `visible`: the box's margin around the text, and how much of it counts as the
    /// piece, as fractions of the font size.
    static func layout(_ string: String, font: CTFont, color: StoryColor, alignment: StoryAlignment, lineSpacing: CGFloat,
                       pad padRatio: CGFloat, visible: CGFloat) -> Layout? {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var align: CTTextAlignment = switch alignment {
        case .center: .center
        case .left: .left
        case .right: .right
        }
        let fontSize = CTFontGetSize(font)
        var spacing = lineSpacing * fontSize
        let para: CTParagraphStyle = withUnsafePointer(to: &align) { a in
            withUnsafePointer(to: &spacing) { sp in
                let settings = [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a),
                                CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: sp)]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cg,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                               CGSize(width: textWrap, height: .greatestFiniteMagnitude), nil)
        let pad = (fontSize * padRatio).rounded(.up)
        let textW = ceil(fit.width) + 2, textH = ceil(fit.height) + 2
        let size = CGSize(width: textW + 2 * pad, height: textH + 2 * pad)
        let path = CGPath(rect: CGRect(x: pad, y: pad, width: textW, height: textH), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)

        let lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        var rects: [CGRect] = []
        let hpad = fontSize * 0.26, vpad = fontSize * 0.1
        for (line, o) in zip(lines, origins) {
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading)) - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            guard width > 0 else { continue }
            rects.append(CGRect(x: pad + o.x - hpad, y: pad + o.y - descent - vpad, width: width + 2 * hpad, height: ascent + descent + 2 * vpad))
        }
        return Layout(size: size, inset: max(0, pad - fontSize * visible), frame: frame, lineRects: rects, fontSize: fontSize)
    }

    /// The item's box in units (before its scale), for hit testing and handles.
    static func size(of kind: StoryItem.Kind) -> CGSize {
        layout(kind)?.size ?? CGSize(width: 200, height: 120)
    }

    // MARK: Drawing items

    /// Draws an item in a y-down context whose origin is the top-left of the item's box.
    static func draw(_ kind: StoryItem.Kind, layout l: Layout, in ctx: CGContext, ppu: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        // Core Text is y-up: flip within the box.
        ctx.translateBy(x: 0, y: l.size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = .identity
        guard case .text(let t) = kind else {
            CTFrameDraw(l.frame, ctx)
            return
        }
        if t.highlight != .none, !l.lineRects.isEmpty {
            let path = CGMutablePath()
            let r = l.fontSize * 0.2
            for rect in l.lineRects { path.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r) }
            ctx.addPath(path)
            ctx.setFillColor((t.highlight == .solid ? t.color : t.color.with(alpha: 0.5)).cg)
            ctx.fillPath(using: .winding)
        }
        if t.style == .neon {
            // A wide coloured glow, a tighter one, then the pale core.
            ctx.setShadow(offset: .zero, blur: l.fontSize * 0.45 * ppu, color: t.color.cg)
            CTFrameDraw(l.frame, ctx)
            ctx.setShadow(offset: .zero, blur: l.fontSize * 0.14 * ppu, color: t.color.cg)
            CTFrameDraw(l.frame, ctx)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
        } else if t.highlight == .none {
            // A faint shadow keeps plain text readable on any picture, as Instagram's does.
            ctx.setShadow(offset: .zero, blur: l.fontSize * 0.08 * ppu, color: CGColor(gray: 0, alpha: 0.25))
        }
        CTFrameDraw(l.frame, ctx)
    }

    /// Draws an item at its place, turn and size in a y-down canvas context.
    static func place(_ item: StoryItem, in ctx: CGContext, ppu: CGFloat) {
        guard let l = layout(item.kind) else { return }
        ctx.saveGState()
        ctx.translateBy(x: item.center.x, y: item.center.y)
        ctx.rotate(by: item.rotation)
        ctx.scaleBy(x: item.scale, y: item.scale)
        ctx.translateBy(x: -l.size.width / 2, y: -l.size.height / 2)
        draw(item.kind, layout: l, in: ctx, ppu: ppu * item.scale)
        ctx.restoreGState()
    }

    /// An item alone, as an image `ppu` pixels per unit, and its box in units.
    static func image(of kind: StoryItem.Kind, ppu: CGFloat) -> (image: CGImage, size: CGSize, inset: CGFloat)? {
        guard let l = layout(kind) else { return nil }
        let w = Int((l.size.width * ppu).rounded(.up)), h = Int((l.size.height * ppu).rounded(.up))
        guard let ctx = context(width: w, height: h) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: ppu, y: -ppu)
        draw(kind, layout: l, in: ctx, ppu: ppu)
        return ctx.makeImage().map { ($0, l.size, l.inset) }
    }

    // MARK: Drawing strokes

    /// A smooth path through the points (quadratic curves through the midpoints).
    static func path(_ points: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let first = points.first else { return p }
        p.move(to: first)
        guard points.count > 1 else {
            p.addLine(to: first)
            return p
        }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            p.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
        }
        p.addLine(to: points[points.count - 1])
        return p
    }

    /// How each brush looks: line width, colour, cap, and a glow.
    struct BrushLook {
        var width: CGFloat
        var color: StoryColor
        var square: Bool
        var glow: CGFloat
        var core: StoryColor?
    }

    static func look(_ s: StoryStroke) -> BrushLook {
        switch s.brush {
        case .pen: BrushLook(width: s.width, color: s.color, square: false, glow: 0)
        case .marker: BrushLook(width: s.width * 2.2, color: s.color.with(alpha: 0.6), square: true, glow: 0)
        case .neon: BrushLook(width: s.width, color: s.color, square: false, glow: s.width * 1.6, core: s.color.lighter(0.8))
        case .eraser: BrushLook(width: s.width * 2.4, color: .black, square: false, glow: 0)
        }
    }

    static func draw(_ s: StoryStroke, in ctx: CGContext, ppu: CGFloat) {
        let l = look(s)
        let path = path(s.points)
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(l.square ? .butt : .round)
        ctx.setLineJoin(.round)
        if s.brush == .eraser { ctx.setBlendMode(.clear) }
        if l.glow > 0 { ctx.setShadow(offset: .zero, blur: l.glow * ppu, color: l.color.cg) }
        ctx.setLineWidth(l.width)
        ctx.setStrokeColor(l.color.cg)
        ctx.addPath(path)
        ctx.strokePath()
        if let core = l.core {
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setLineWidth(l.width * 0.45)
            ctx.setStrokeColor(core.cg)
            ctx.addPath(path)
            ctx.strokePath()
        }
    }

    /// The drawing layer alone (the eraser only clears drawing), `ppu` pixels per unit.
    static func drawing(_ strokes: [StoryStroke], ppu: CGFloat) -> CGImage? {
        guard !strokes.isEmpty else { return nil }
        let w = Int((canvas.width * ppu).rounded()), h = Int((canvas.height * ppu).rounded())
        guard let ctx = yDown(width: w, height: h, ppu: ppu) else { return nil }
        for s in strokes { draw(s, in: ctx, ppu: ppu) }
        return ctx.makeImage()
    }

    /// Drawing, then text and stickers in order, over transparency: 1080×1920.
    static func overlay(_ doc: StoryDoc) -> CGImage? {
        guard !doc.isBlank else { return nil }
        guard let ctx = yDown(width: Int(canvas.width), height: Int(canvas.height), ppu: 1) else { return nil }
        if let d = drawing(doc.strokes, ppu: 1) {
            // `draw` is y-up: flip for the image.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: canvas.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(d, in: CGRect(origin: .zero, size: canvas))
            ctx.restoreGState()
        }
        for item in doc.items { place(item, in: ctx, ppu: 1) }
        return ctx.makeImage()
    }

    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func yDown(width: Int, height: Int, ppu: CGFloat) -> CGContext? {
        guard let ctx = context(width: width, height: height) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: ppu, y: -ppu)
        ctx.interpolationQuality = .high
        return ctx
    }

    // MARK: Background

    /// Two colours from the picture, top and bottom, for the gradient that fills the canvas
    /// around it (as Instagram fills a photo that isn't 9:16).
    static func gradient(from image: CGImage) -> (top: StoryColor, bottom: StoryColor) {
        let n = 8
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let ok: Bool = px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return (StoryColor(hex: 0x833AB4), StoryColor(hex: 0xF77737)) }
        func average(rows: Range<Int>) -> StoryColor {
            var r = 0.0, g = 0.0, b = 0.0
            for y in rows { for x in 0..<n {
                let i = (y * n + x) * 4
                r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2])
            } }
            let c = Double(rows.count * n) * 255
            // A little darker, so text and the picture stand out from it.
            return StoryColor(r: r / c * 0.82, g: g / c * 0.82, b: b / c * 0.82)
        }
        return (average(rows: 0..<n / 2), average(rows: n / 2..<n))
    }

    /// The finished frame: gradient, the picture placed and filtered, then the overlay —
    /// one Core Image recipe for the photo export and each video frame.
    static func compose(source: CIImage, doc: StoryDoc, gradient: (top: StoryColor, bottom: StoryColor), overlay: CIImage?) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvas)
        let e = source.extent
        let bg = doc.bgRect(aspect: e.width / max(e.height, 1))
        let placed = doc.filter.apply(source)
            .transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
                .concatenating(CGAffineTransform(scaleX: bg.width / e.width, y: bg.height / e.height))
                // Core Image is y-up.
                .concatenating(CGAffineTransform(translationX: bg.minX, y: canvas.height - bg.maxY)))
        let fill = CIFilter.linearGradient()
        fill.point0 = CGPoint(x: 0, y: canvas.height)
        fill.point1 = .zero
        fill.color0 = CIColor(cgColor: gradient.top.cg)
        fill.color1 = CIColor(cgColor: gradient.bottom.cg)
        var out = placed.composited(over: (fill.outputImage ?? CIImage(color: .black)).cropped(to: canvasRect))
        if let overlay { out = overlay.composited(over: out) }
        return out.cropped(to: canvasRect)
    }
}

// MARK: - Filters

nonisolated extension StoryFilter {
    /// Colour-only adjustments (no blur or vignette), so they look the same at any size.
    func apply(_ image: CIImage) -> CIImage {
        func controls(_ i: CIImage, saturation: Float = 1, brightness: Float = 0, contrast: Float = 1) -> CIImage {
            let f = CIFilter.colorControls()
            f.inputImage = i
            f.saturation = saturation
            f.brightness = brightness
            f.contrast = contrast
            return f.outputImage ?? i
        }
        func matrix(_ i: CIImage, r: CGFloat, g: CGFloat, b: CGFloat, bias: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)) -> CIImage {
            let f = CIFilter.colorMatrix()
            f.inputImage = i
            f.rVector = CIVector(x: r, y: 0, z: 0, w: 0)
            f.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
            f.bVector = CIVector(x: 0, y: 0, z: b, w: 0)
            f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            f.biasVector = CIVector(x: bias.0, y: bias.1, z: bias.2, w: 0)
            return f.outputImage ?? i
        }
        switch self {
        case .normal:
            return image
        case .paris:
            return matrix(controls(image, saturation: 0.92, brightness: 0.03, contrast: 0.92), r: 1.03, g: 0.99, b: 1.02, bias: (0.03, 0.01, 0.04))
        case .oslo:
            return matrix(controls(image, saturation: 0.72, brightness: 0.02, contrast: 0.9), r: 0.94, g: 1.0, b: 1.06, bias: (0.02, 0.03, 0.06))
        case .lagos:
            return matrix(controls(image, saturation: 1.25, contrast: 1.06), r: 1.08, g: 1.02, b: 0.88, bias: (0.02, 0, 0))
        case .tokyo:
            let f = CIFilter.photoEffectNoir()
            f.inputImage = image
            return controls(f.outputImage ?? image, brightness: 0.02, contrast: 1.05)
        case .cairo:
            let f = CIFilter.sepiaTone()
            f.inputImage = image
            f.intensity = 0.4
            return controls(f.outputImage ?? image, saturation: 0.9, brightness: 0.02, contrast: 0.94)
        case .jaipur:
            let v = CIFilter.vibrance()
            v.inputImage = image
            v.amount = 0.7
            return controls(v.outputImage ?? image, saturation: 1.08, contrast: 1.14)
        }
    }
}
