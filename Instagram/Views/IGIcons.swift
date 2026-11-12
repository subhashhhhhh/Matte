import SwiftUI
import ImageIO

/// Instagram's own glyphs (the SVG paths instagram.com draws), so actions look like Instagram
/// rather than SF Symbols.
enum IGIcon: CaseIterable {
    case heart, heartFilled, comment, share, save, saveFilled, home, homeFilled, reels, reelsFilled, direct, directFilled
    case more, explore, exploreFilled, search

    fileprivate var spec: (path: String, box: CGFloat, stroked: Bool) {
        switch self {
        case .heart:
            ("M16.792 3.904A4.989 4.989 0 0 1 21.5 9.122c0 3.072-2.652 4.959-5.197 7.222-2.512 2.243-3.865 3.469-4.303 3.752-.477-.309-2.143-1.823-4.303-3.752C5.141 14.072 2.5 12.167 2.5 9.122a4.989 4.989 0 0 1 4.708-5.218 4.21 4.21 0 0 1 3.675 1.941c.84 1.175.98 1.763 1.12 1.763s.278-.588 1.11-1.766a4.17 4.17 0 0 1 3.679-1.938m0-2a6.04 6.04 0 0 0-4.797 2.127 6.052 6.052 0 0 0-4.787-2.127A6.985 6.985 0 0 0 .5 9.122c0 3.61 2.55 5.827 5.015 7.97.283.246.569.494.853.747l1.027.918a44.998 44.998 0 0 0 3.518 3.018 2 2 0 0 0 2.174 0 45.263 45.263 0 0 0 3.626-3.115l.922-.824c.293-.26.59-.519.885-.774 2.334-2.025 4.98-4.32 4.98-7.94a6.985 6.985 0 0 0-6.708-7.218Z", 24, false)
        case .heartFilled:
            ("M34.6 3.1c-4.5 0-7.9 1.8-10.6 5.6-2.7-3.7-6.1-5.5-10.6-5.5C6 3.1 0 9.6 0 17.6c0 7.3 5.4 12 10.6 16.5.6.5 1.3 1.1 1.9 1.7l2.3 2c4.4 3.9 6.6 5.9 7.6 6.5.5.3 1.1.5 1.6.5s1.1-.2 1.6-.5c1-.6 2.8-2.2 7.8-6.8l2-1.8c.7-.6 1.3-1.2 2-1.7C42.7 29.6 48 25 48 17.6c0-8-6-14.5-13.4-14.5z", 48, false)
        case .comment:
            ("M20.656 17.008a9.993 9.993 0 1 0-3.59 3.615L22 22Z", 24, true)
        case .share, .direct:
            ("M22 3 9.218 10.083M11.698 20.334 22 3.001H2l7.218 7.083 2.48 10.25Z", 24, true)
        case .directFilled:
            ("M11.698 20.334 22 3.001H2l7.218 7.083 2.48 10.25Z", 24, false)
        case .save:
            ("M20 21 12 13.44 4 21V3h16Z", 24, true)
        case .saveFilled:
            ("M20 22a.999.999 0 0 1-.687-.273L12 14.815l-7.313 6.912A1 1 0 0 1 3 21V3a1 1 0 0 1 1-1h16a1 1 0 0 1 1 1v18a1 1 0 0 1-1 1Z", 24, false)
        case .home:
            ("M9.005 16.545a2.997 2.997 0 0 1 2.997-2.997A2.997 2.997 0 0 1 15 16.545V22h7V11.543L12 2 2 11.543V22h7.005Z", 24, true)
        case .homeFilled:
            ("M22 23h-6.001a1 1 0 0 1-1-1v-5.455a2.997 2.997 0 1 0-5.993 0V22a1 1 0 0 1-1 1H2a1 1 0 0 1-1-1V11.543a1.002 1.002 0 0 1 .31-.724l10-9.543a1.001 1.001 0 0 1 1.38 0l10 9.543a1.002 1.002 0 0 1 .31.724V22a1 1 0 0 1-1 1Z", 24, false)
        case .reels:
            ("M2.049 7.002h19.902M13.504 2.001l2.994 5.001M7.207 2.11l2.92 4.892M2 12.001v3.449c0 2.849.698 4.006 1.606 4.945.94.908 2.098 1.607 4.946 1.607h6.896c2.848 0 4.006-.699 4.946-1.607.908-.939 1.606-2.096 1.606-4.945V8.552c0-2.848-.698-4.006-1.606-4.945C19.454 2.699 18.296 2 15.448 2H8.552c-2.848 0-4.006.699-4.946 1.607C2.698 4.546 2 5.704 2 8.552ZM9.763 17.664V11.63l5.454 3.017Z", 24, true)
        case .reelsFilled:
            ("M12.823 1l2.974 5.002h-5.58l-2.65-4.971c.206-.013.419-.022.642-.027L8.55 1Zm2.327 0h.298c3.06 0 4.468.754 5.64 1.887a6.007 6.007 0 0 1 1.596 2.82l.07.295h-4.629L15.15 1Zm-9.667.377L7.95 6.002H1.244a6.01 6.01 0 0 1 3.942-4.53Zm9.735 12.834-4.545-2.624a.909.909 0 0 0-1.356.668l-.008.12v5.248a.91.91 0 0 0 1.255.84l.109-.053 4.545-2.624a.909.909 0 0 0 .1-1.507l-.1-.068-4.545-2.624Zm-14.2-6.209h21.964l.015.36.003.189v6.899c0 3.061-.755 4.469-1.888 5.64-1.151 1.114-2.5 1.856-5.33 1.909l-.334.003H8.551c-3.06 0-4.467-.755-5.64-1.889-1.114-1.15-1.854-2.498-1.908-5.33L1 15.45V8.551l.003-.189Z", 24, false)
        case .explore:
            ("M13.941 13.953 7.581 16.424 10.06 10.056 16.42 7.585ZM10.06 10.056l3.881 3.897M22.5 12a10.5 10.5 0 1 1-21 0 10.5 10.5 0 0 1 21 0Z", 24, true)
        case .exploreFilled:
            ("m13.173 13.164 1.491-3.829-3.83 1.49ZM12.001.5a11.5 11.5 0 1 0 11.5 11.5A11.513 11.513 0 0 0 12.001.5Zm5.35 7.443-2.478 6.369a1 1 0 0 1-.57.569l-6.36 2.47a1 1 0 0 1-1.294-1.294l2.48-6.369a1 1 0 0 1 .57-.569l6.359-2.47a1 1 0 0 1 1.294 1.294Z", 24, false)
        case .search:
            ("M19 10.5A8.5 8.5 0 1 1 10.5 2a8.5 8.5 0 0 1 8.5 8.5ZM16.511 16.511 22 22", 24, true)
        case .more:
            ("M6.5 12a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0Zm7 0a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0Zm7 0a1.5 1.5 0 1 1-3 0 1.5 1.5 0 0 1 3 0Z", 24, false)
        }
    }
}

/// Draws an `IGIcon` at `size` points, in the current foreground style.
struct IGGlyph: View {
    let icon: IGIcon
    var size: CGFloat = 24

    var body: some View {
        let spec = icon.spec
        let shape = SVGPathShape(path: spec.path, box: spec.box)
        Group {
            if spec.stroked {
                shape.stroke(style: StrokeStyle(lineWidth: 2 * size / 24, lineCap: .round, lineJoin: .round))
            } else {
                shape.fill(style: FillStyle(eoFill: true))
            }
        }
        .frame(width: size, height: size)
    }
}

/// A shape from SVG path data in a `box`×`box` view box, scaled to fit its frame.
nonisolated struct SVGPathShape: Shape {
    let path: String
    let box: CGFloat

    func path(in rect: CGRect) -> Path {
        let base = SVGPath.parse(path)
        let scale = min(rect.width, rect.height) / box
        return base.applying(CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}

/// A small SVG path-data parser: M L H V C S Q Z and circular/elliptical A, absolute and relative.
nonisolated enum SVGPath {
    nonisolated(unsafe) private static var cache: [String: Path] = [:]
    private static let lock = NSLock()

    static func parse(_ d: String) -> Path {
        lock.lock(); defer { lock.unlock() }
        if let p = cache[d] { return p }
        var tokens = Tokenizer(d)
        var path = Path()
        var current = CGPoint.zero, start = CGPoint.zero, lastControl: CGPoint?
        var command: Character = "M"

        while let next = tokens.peekCommandOrNumber() {
            if case .command(let c) = next { command = c; tokens.advance() }
            let rel = command.isLowercase
            func pt() -> CGPoint? {
                guard let x = tokens.number(), let y = tokens.number() else { return nil }
                return rel ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command.uppercased().first! {
            case "M":
                guard let p = pt() else { break }
                path.move(to: p); current = p; start = p; lastControl = nil
                command = rel ? "l" : "L"
            case "L":
                guard let p = pt() else { break }
                path.addLine(to: p); current = p; lastControl = nil
            case "H":
                guard let x = tokens.number() else { break }
                current.x = rel ? current.x + x : x; path.addLine(to: current); lastControl = nil
            case "V":
                guard let y = tokens.number() else { break }
                current.y = rel ? current.y + y : y; path.addLine(to: current); lastControl = nil
            case "C":
                guard let c1 = pt(), let c2 = pt(), let p = pt() else { break }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case "S":
                let c1 = lastControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                guard let c2 = pt(), let p = pt() else { break }
                path.addCurve(to: p, control1: c1, control2: c2); current = p; lastControl = c2
            case "Q":
                guard let c = pt(), let p = pt() else { break }
                path.addQuadCurve(to: p, control: c); current = p; lastControl = nil
            case "A":
                guard let rx = tokens.number(), let ry = tokens.number(), let rot = tokens.number(),
                      let large = tokens.flag(), let sweep = tokens.flag(), let p = pt() else { break }
                addArc(&path, from: current, to: p, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                current = p; lastControl = nil
            case "Z":
                path.closeSubpath(); current = start; lastControl = nil
                // A number right after Z would be malformed; skip to the next command.
                if case .number = tokens.peekCommandOrNumber() { _ = tokens.number() }
            default:
                tokens.advance()
            }
        }
        cache[d] = path
        return path
    }

    /// SVG endpoint arc → center parameterisation, drawn as cubic segments.
    private static func addArc(_ path: inout Path, from p0: CGPoint, to p1: CGPoint, rx: CGFloat, ry: CGFloat,
                               rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry, cy1 = -coef * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (p0.x + p1.x) / 2
        let cy = sinP * cx1 + cosP * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi } else if sweep, delta < 0 { delta += 2 * .pi }
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        let t = 4 / 3 * tan(step / 4)
        var a = theta1
        func point(_ a: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(a) * cosP - ry * sin(a) * sinP, y: cy + rx * cos(a) * sinP + ry * sin(a) * cosP)
        }
        func deriv(_ a: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(a) * cosP - ry * cos(a) * sinP, y: -rx * sin(a) * sinP + ry * cos(a) * cosP)
        }
        for _ in 0..<segments {
            let b = a + step
            let pa = point(a), pb = point(b), da = deriv(a), db = deriv(b)
            path.addCurve(to: pb, control1: CGPoint(x: pa.x + t * da.x, y: pa.y + t * da.y),
                          control2: CGPoint(x: pb.x - t * db.x, y: pb.y - t * db.y))
            a = b
        }
    }

    private struct Tokenizer {
        enum Token { case command(Character), number }
        let chars: [Character]
        var i = 0
        init(_ s: String) { chars = Array(s) }

        mutating func skip() { while i < chars.count, chars[i] == " " || chars[i] == "," || chars[i] == "\n" { i += 1 } }
        mutating func advance() { i += 1 }

        mutating func peekCommandOrNumber() -> Token? {
            skip()
            guard i < chars.count else { return nil }
            let c = chars[i]
            return c.isLetter && c != "e" && c != "E" ? .command(c) : .number
        }

        /// One arc flag: a single 0 or 1, which may be written without a separator ("0 0 1" or "001").
        mutating func flag() -> Bool? {
            skip()
            guard i < chars.count, chars[i] == "0" || chars[i] == "1" else { return nil }
            defer { i += 1 }
            return chars[i] == "1"
        }

        mutating func number() -> CGFloat? {
            skip()
            let begin = i
            if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
            var seenDot = false, seenDigit = false
            while i < chars.count {
                let c = chars[i]
                if c.isNumber { seenDigit = true; i += 1 }
                else if c == ".", !seenDot { seenDot = true; i += 1 }
                else if (c == "e" || c == "E"), seenDigit {
                    i += 1
                    if i < chars.count, chars[i] == "-" || chars[i] == "+" { i += 1 }
                } else { break }
            }
            guard seenDigit else { i = begin; return nil }
            return Double(String(chars[begin..<i])).map { CGFloat($0) }
        }
    }
}

#if DEBUG
/// `-IGIconSheet <file.png>`: renders every icon to an image and quits (to check the paths).
enum IconSheet {
    static func renderIfAsked() {
        guard let out = UserDefaults.standard.string(forKey: "IGIconSheet") else { return }
        let view = HStack(spacing: 16) {
            ForEach(Array(IGIcon.allCases.enumerated()), id: \.offset) { _, icon in IGGlyph(icon: icon, size: 48) }
        }
        .padding(20).foregroundStyle(.black).background(.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.cgImage, let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        exit(0)
    }
}
#endif
