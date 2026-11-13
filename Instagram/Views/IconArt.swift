#if DEBUG
import SwiftUI

/// The app icon, drawn in SwiftUI (1024 canvas, macOS grid: an 824 squircle with its shadow)
/// so it can be re-rendered: `-IGRenderIcon <folder>` writes each concept as a PNG and quits.
struct IconArt: View {
    enum Concept: String, CaseIterable { case darkroom, print, paper }
    let concept: Concept
    /// Just the artwork, edge to edge (for Icon Composer, which adds the shape and shadow).
    var flat = false

    private let body824: CGFloat = 824
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 185, style: .continuous) }

    var body: some View {
        if flat {
            art.frame(width: body824, height: body824).scaleEffect(1024 / body824).frame(width: 1024, height: 1024)
        } else {
            framed
        }
    }

    @ViewBuilder
    private var art: some View {
        switch concept {
        case .darkroom: darkroom
        case .print: print
        case .paper: paper
        }
    }

    private var framed: some View {
        ZStack {
            Color.clear
            ZStack {
                switch concept {
                case .darkroom: darkroom
                case .print: print
                case .paper: paper
                }
            }
            .frame(width: body824, height: body824)
            .clipShape(shape)
            .overlay(shape.strokeBorder(.white.opacity(0.06), lineWidth: 2))
            .compositingGroup()
            .shadow(color: .black.opacity(0.35), radius: 18, y: 12)
        }
        .frame(width: 1024, height: 1024)
    }

    /// The script M centred by its ink (the glyph's outline), not its text box: the letter
    /// leans and swashes far to the right of where the font places it.
    private func monogram(_ color: Color, size: CGFloat) -> some View {
        let font = CTFontCreateWithName("SnellRoundhand-Black" as CFString, size, nil)
        var glyph = CGGlyph(0)
        var ch: UniChar = 77 // "M"
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
        let ink = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        let path = (CTFontCreatePathForGlyph(font, glyph, nil).map { Path($0) } ?? Path())
            .offsetBy(dx: -ink.midX, dy: -ink.midY)
            .applying(CGAffineTransform(scaleX: 1, y: -1))
        return Canvas { ctx, size in
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.fill(path, with: .color(color))
        }
    }

    /// Warm black, one dim safelight from above, fine grain, a paper-white M.
    private var darkroom: some View {
        ZStack {
            Darkroom.black
            RadialGradient(colors: [Darkroom.safelight.opacity(0.32), Darkroom.safelight.opacity(0.08), .clear],
                           center: UnitPoint(x: 0.5, y: -0.1), startRadius: 0, endRadius: 760)
            RadialGradient(colors: [.clear, .black.opacity(0.35)], center: .center, startRadius: 260, endRadius: 620)
            FilmGrain().scaleEffect(2)
            monogram(Darkroom.paper, size: 430)
        }
    }

    /// A small print: warm black image area inside a paper border, the M on it.
    private var print: some View {
        ZStack {
            Darkroom.paper
            ZStack {
                Darkroom.black
                RadialGradient(colors: [Darkroom.safelight.opacity(0.28), .clear],
                               center: UnitPoint(x: 0.5, y: -0.1), startRadius: 0, endRadius: 600)
                FilmGrain().scaleEffect(2)
                monogram(Darkroom.paper, size: 340)
            }
            .frame(width: 824 - 136, height: 824 - 196)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .offset(y: -22)
        }
    }

    /// Matte photo paper: off-white, faint grain, a warm-black M as if printed on it.
    private var paper: some View {
        ZStack {
            Darkroom.paper
            LinearGradient(colors: [.white.opacity(0.35), .clear, .black.opacity(0.06)], startPoint: .top, endPoint: .bottom)
            FilmGrain().scaleEffect(2).opacity(0.7)
            monogram(Darkroom.black, size: 430)
        }
    }

    static func renderIfAsked() {
        guard let dir = UserDefaults.standard.string(forKey: "IGRenderIcon") else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            // The shipped icon's two looks, flat for AppIcon.icon.
            for (concept, name) in [(Concept.paper, "flat-paper"), (.darkroom, "flat-darkroom")] {
                let r = ImageRenderer(content: IconArt(concept: concept, flat: true))
                r.scale = 1
                if let cg = r.cgImage, let dest = CGImageDestinationCreateWithURL(
                    URL(fileURLWithPath: dir).appending(path: "\(name).png") as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, cg, nil)
                    CGImageDestinationFinalize(dest)
                }
            }
            for concept in Concept.allCases {
                let r = ImageRenderer(content: IconArt(concept: concept))
                r.scale = 1
                guard let cg = r.cgImage,
                      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: dir).appending(path: "icon-\(concept.rawValue).png") as CFURL,
                                                                 "public.png" as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(dest, cg, nil)
                CGImageDestinationFinalize(dest)
            }
            exit(0)
        }
    }
}
#endif
