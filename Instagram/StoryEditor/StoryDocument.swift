import CoreGraphics
import Foundation

/// Everything the story editor lets you change, as plain values: what undo snapshots, what
/// the renderer draws, and what export flattens. Positions are in canvas units: the finished
/// story is 1080×1920 and one unit is one pixel of it (y down, as on screen).
nonisolated struct StoryDoc: Equatable, Sendable {
    static let size = CGSize(width: 1080, height: 1920)

    var items: [StoryItem] = []
    var strokes: [StoryStroke] = []
    /// The background's zoom (1 = fitted inside the canvas) and its centre's offset from the
    /// canvas centre.
    var bgScale: CGFloat = 1
    var bgOffset: CGSize = .zero
    var filter: StoryFilter = .normal
    /// What fills the canvas around the picture.
    var background: StoryBackground = .gradient
    /// A shared reel's look: rounded corners and the author/duration labels with the picture.
    var frame: StoryPictureFrame?
    /// A shared photo post's song: the story is shared as a video with it (unless `muted`).
    var music: MusicTrack?
    /// Video only: the part that's kept (seconds) and whether its sound is.
    var trimStart: Double = 0
    var trimEnd: Double = 0
    var muted = false

    var isBlank: Bool { items.isEmpty && strokes.isEmpty && (frame?.hasLabels != true) }

    /// Where the background sits in the canvas for a picture of `aspect` (width / height).
    func bgRect(aspect: CGFloat) -> CGRect {
        let c = Self.size
        var w = c.width, h = c.width / max(aspect, 0.01)
        if h > c.height { h = c.height; w = h * aspect }
        w *= bgScale; h *= bgScale
        return CGRect(x: c.width / 2 + bgOffset.width - w / 2, y: c.height / 2 + bgOffset.height - h / 2, width: w, height: h)
    }
}

/// How a shared reel's video is framed, as the phone app shows it: full screen with the
/// author's name at the top, or a rounded card with the name and the length inside it.
nonisolated struct StoryPictureFrame: Equatable, Sendable {
    /// Corner radius in canvas units (0 = square).
    var radius: CGFloat = 0
    var leading: String?
    var trailing: String?
    /// Labels inside the picture's top edge (card), or at the top of the story (full screen).
    var inside = false
    /// The picture's width / height (for placing the labels without the picture at hand).
    var aspect: CGFloat = 9.0 / 16

    var hasLabels: Bool { leading != nil || trailing != nil }

    /// Where the labels go, in canvas units: (leading's top-left, trailing's top-right).
    func labelAnchors(in doc: StoryDoc) -> (leading: CGPoint, trailing: CGPoint) {
        if inside {
            let r = doc.bgRect(aspect: aspect)
            return (CGPoint(x: r.minX + 40, y: r.minY + 40), CGPoint(x: r.maxX - 40, y: r.minY + 40))
        }
        return (CGPoint(x: 64, y: 150), CGPoint(x: StoryDoc.size.width - 64, y: 150))
    }

    static let labelSize: CGFloat = 40
}

/// What fills the story around the picture: two colours from it (as Instagram fills a photo
/// that isn't 9:16), the picture itself blurred (as the phone app does for a shared post), or
/// one colour.
nonisolated enum StoryBackground: Equatable, Hashable, Sendable {
    case gradient
    case blur
    case color(StoryColor)
}

/// A piece of text or a sticker on the canvas.
nonisolated struct StoryItem: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case text(StoryText)
        case sticker(String)
    }

    var id = UUID()
    var kind: Kind
    var center = CGPoint(x: StoryDoc.size.width / 2, y: StoryDoc.size.height / 2)
    var scale: CGFloat = 1
    /// Radians, clockwise on screen.
    var rotation: Double = 0

    var text: StoryText? {
        if case .text(let t) = kind { return t }
        return nil
    }
}

/// Instagram's story text styles, drawn with fonts every Mac has.
nonisolated enum StoryTextStyle: String, CaseIterable, Sendable, Identifiable {
    case classic, modern, typewriter, strong, neon
    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .modern: "Modern"
        case .typewriter: "Typewriter"
        case .strong: "Strong"
        case .neon: "Neon"
        }
    }

    /// PostScript names, tried in order (the system font if none is installed).
    var fontNames: [String] {
        switch self {
        case .classic: ["HelveticaNeue-Bold"]
        case .modern: ["AvenirNext-HeavyItalic", "Futura-MediumItalic"]
        case .typewriter: ["AmericanTypewriter-Semibold", "CourierNewPS-BoldMT"]
        case .strong: ["Futura-CondensedExtraBold", "HelveticaNeue-CondensedBlack"]
        case .neon: ["SnellRoundhand-Black", "Noteworthy-Bold"]
        }
    }

    var uppercased: Bool { self == .strong }
    /// Font size in canvas units at scale 1.
    var size: CGFloat {
        switch self {
        case .classic: 76
        case .modern: 74
        case .typewriter: 68
        case .strong: 96
        case .neon: 92
        }
    }
}

nonisolated enum StoryHighlight: Int, CaseIterable, Sendable {
    case none, solid, translucent
    var next: StoryHighlight { StoryHighlight(rawValue: (rawValue + 1) % 3) ?? .none }
}

nonisolated enum StoryAlignment: Int, CaseIterable, Sendable {
    case center, left, right
    var next: StoryAlignment { StoryAlignment(rawValue: (rawValue + 1) % 3) ?? .center }
}

nonisolated struct StoryText: Equatable, Sendable {
    var string = ""
    var style: StoryTextStyle = .classic
    var color: StoryColor = .white
    var alignment: StoryAlignment = .center
    var highlight: StoryHighlight = .none
}

/// An sRGB colour that can be compared and sent across threads.
nonisolated struct StoryColor: Equatable, Hashable, Sendable {
    var r: Double, g: Double, b: Double, a: Double = 1

    static let white = StoryColor(r: 1, g: 1, b: 1)
    static let black = StoryColor(r: 0, g: 0, b: 0)

    /// Instagram's story palette.
    static let palette: [StoryColor] = [
        .white, .black,
        StoryColor(hex: 0x3897F0), StoryColor(hex: 0x70C050), StoryColor(hex: 0xFDCB5C), StoryColor(hex: 0xFD8D32),
        StoryColor(hex: 0xED4956), StoryColor(hex: 0xD10869), StoryColor(hex: 0xA307BA), StoryColor(hex: 0xFFD3D3),
        StoryColor(hex: 0x6B4226), StoryColor(hex: 0x262626), StoryColor(hex: 0x8E8E8E), StoryColor(hex: 0x00C8C8),
    ]

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: Int) {
        self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
    }

    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    func with(alpha: Double) -> StoryColor { StoryColor(r: r, g: g, b: b, a: alpha) }
    /// Mixed toward white by `t` (0…1).
    func lighter(_ t: Double) -> StoryColor { StoryColor(r: r + (1 - r) * t, g: g + (1 - g) * t, b: b + (1 - b) * t, a: a) }
    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }
    /// Black or white, whichever reads on this colour.
    var contrasting: StoryColor { luminance > 0.6 ? .black : .white }
}

/// One stroke of the drawing tool.
nonisolated struct StoryStroke: Equatable, Sendable {
    enum Brush: String, CaseIterable, Sendable, Identifiable {
        case pen, marker, neon, eraser
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pen: "Pen"
            case .marker: "Marker"
            case .neon: "Neon"
            case .eraser: "Eraser"
            }
        }
    }

    /// The three sizes, in canvas units.
    static let widths: [CGFloat] = [9, 18, 34]

    var brush: Brush
    var color: StoryColor
    var width: CGFloat
    var points: [CGPoint]
}

/// The filter presets (colour only, so a preview at screen size matches the full-size export).
nonisolated enum StoryFilter: String, CaseIterable, Sendable, Identifiable {
    case normal, paris, oslo, lagos, tokyo, cairo, jaipur
    var id: String { rawValue }
    var title: String { self == .normal ? "Normal" : rawValue.capitalized }
}
