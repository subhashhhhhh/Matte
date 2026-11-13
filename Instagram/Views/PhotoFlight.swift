import SwiftUI
import AppKit

/// Lumen's photo open/close, ported: a copy of the photo flies between its tile and the post
/// viewer while both stay hidden, so the photo grows out of (and lands back in) its own slot.
///
/// Position and size animate separately, with Lumen's springs: opening is quick and smooth with a
/// hint of settle; landing lets the position carry a little while the size never overshoots
/// (shrinking past the tile and back reads as a second animation). The backdrop's darkness
/// follows how grown the photo is. The photo is decoded once at full size when clicked and
/// handed to the viewer, so nothing reloads or flashes at the hand-off.
@Observable
final class PhotoFlight {
    static let space = "photoFlight"

    /// Where tiles are (in the host's coordinate space) and their corner radius, by media pk.
    @ObservationIgnored private var cells: [String: (frame: CGRect, radius: CGFloat)] = [:]
    /// The host's size, for working out where the photo lands in the viewer.
    @ObservationIgnored var hostSize: CGSize = .zero

    /// The photo in flight (nil when idle).
    private(set) var media: Media?
    private(set) var opening = false
    private(set) var center: CGPoint = .zero
    private(set) var grown: CGFloat = 0
    private(set) var thumb: CGRect = .zero
    private(set) var full: CGRect = .zero
    private(set) var thumbRadius: CGFloat = 0
    /// No tile to land in (scrolled away): shrink in place and fade instead.
    private(set) var landless = false
    private(set) var backdropStart: CGFloat = 1
    /// The photo decoded at the viewer's size, kept for the viewer and the flight back.
    private(set) var image: CGImage?
    @ObservationIgnored private var imagePk: String?
    @ObservationIgnored private var decodeTask: Task<Void, Never>?

    // Lumen's springs (Compose stiffness/damping → response = 2π/√stiffness).
    private static var openPosition: Animation { .spring(response: 0.351, dampingFraction: 0.9) }
    private static var openSize: Animation { .spring(response: 0.351, dampingFraction: 0.9) }
    private static var landPosition: Animation { .spring(response: 0.414, dampingFraction: 0.82) }
    private static var landSize: Animation { .spring(response: 0.39, dampingFraction: 1.0) }

    var isFlying: Bool { media != nil }
    func isFlying(_ pk: String) -> Bool { media?.pk == pk }

    func register(_ pk: String, frame: CGRect, radius: CGFloat) { cells[pk] = (frame, radius) }
    func forget(_ pk: String) { cells[pk] = nil }

    /// The decoded photo for the viewer to start with (nil if it's another post or not ready).
    func handoff(for pk: String) -> CGImage? { imagePk == pk ? image : nil }

    /// Grows `media` from its tile to `target`; `arrived` runs when it's full size (show the viewer).
    func open(_ media: Media, to target: CGRect, arrived: @escaping () -> Void) {
        guard !isFlying else { return }
        let cell = cells[media.pk]
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            self.media = media
            opening = true
            landless = cell == nil
            thumb = cell?.frame ?? Self.shrunk(target)
            thumbRadius = cell?.radius ?? 12
            full = target
            center = CGPoint(x: thumb.midX, y: thumb.midY)
            grown = 0
            backdropStart = 1
        }
        decode(media, at: target.size)
        // Next frame, so the starting state is drawn before it moves.
        DispatchQueue.main.async { [self] in
            if Motion.reduced {
                withAnimation(.easeInOut(duration: 0.15)) { center = CGPoint(x: full.midX, y: full.midY); grown = 1 } completion: {
                    self.arrive(arrived)
                }
                return
            }
            withAnimation(Self.openPosition) { center = CGPoint(x: full.midX, y: full.midY) }
            withAnimation(Self.openSize, completionCriteria: .logicallyComplete) { grown = 1 } completion: {
                self.arrive(arrived)
            }
        }
    }

    private func arrive(_ arrived: () -> Void) {
        arrived()
        // Let the viewer draw its first frame (with the handed-off image) before the copy goes.
        DispatchQueue.main.async { [self] in
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { media = nil; opening = false }
        }
    }

    /// Flies `media` back from where the viewer shows it (`from`) into its tile. Call in the same
    /// moment the viewer goes away.
    func close(_ media: Media, from: CGRect, backdrop: CGFloat = 1) {
        let cell = cells[media.pk]
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            self.media = media
            opening = false
            landless = cell == nil
            full = from
            thumb = cell?.frame ?? Self.shrunk(from)
            thumbRadius = cell?.radius ?? 12
            center = CGPoint(x: from.midX, y: from.midY)
            grown = 1
            backdropStart = backdrop
        }
        if imagePk != media.pk { decode(media, at: from.size) }
        DispatchQueue.main.async { [self] in
            let animSize = Motion.reduced ? Animation.easeInOut(duration: 0.15) : Self.landSize
            withAnimation(Motion.reduced ? .easeInOut(duration: 0.15) : Self.landPosition) {
                center = CGPoint(x: thumb.midX, y: thumb.midY)
            }
            withAnimation(animSize, completionCriteria: .logicallyComplete) { grown = 0 } completion: {
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) { self.media = nil }
            }
        }
    }

    /// Decodes the photo at exactly the size the viewer's image view asks for (same URL and
    /// pixel bucket), so the viewer finds it ready.
    private func decode(_ media: Media, at size: CGSize) {
        decodeTask?.cancel()
        if imagePk != media.pk { image = nil }
        imagePk = media.pk
        let first = media.children.first ?? media
        guard let url = first.image(minWidth: 1080) else { return }
        let px = Self.bucket(size)
        // Warmed by hovering: the full-size photo is ready for the very first frame.
        if let hit = ImagePipeline.shared.cachedImage(for: url, maxPixel: px) {
            image = hit
            return
        }
        decodeTask = Task { [weak self] in
            let decoded = await ImagePipeline.shared.image(for: url, maxPixel: px)
            guard !Task.isCancelled, let self, self.imagePk == media.pk else { return }
            self.image = decoded
        }
    }

    /// Decodes a post's full-size photo ahead of a likely click (hovering its tile).
    func warm(_ media: Media) {
        guard hostSize.width > 0, let url = (media.children.first ?? media).image(minWidth: 1080) else { return }
        let px = Self.bucket(PostLightbox.stageRect(in: hostSize, media: media).size)
        Task { await ImagePipeline.shared.warm(url, maxPixel: px) }
    }

    /// Downloads a post's full-size photo to disk when its tile scrolls into view.
    static func prefetch(_ media: Media) {
        guard let url = (media.children.first ?? media).image(minWidth: 1080) else { return }
        Task { await ImagePipeline.shared.prefetch([url]) }
    }

    /// RemoteImage's pixel bucket for a view of `size` (keep in step with RemoteImage).
    static func bucket(_ size: CGSize) -> Int {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let px = Int(max(size.width, size.height) * scale)
        return px <= 0 ? 0 : ((px + 63) / 64) * 64
    }

    private static func shrunk(_ r: CGRect) -> CGRect {
        r.insetBy(dx: r.width * 0.2, dy: r.height * 0.2)
    }

    // MARK: Drawing

    var currentRect: CGRect {
        let g = min(max(grown, 0), 1)
        let w = thumb.width + (full.width - thumb.width) * g
        let h = thumb.height + (full.height - thumb.height) * g
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }

    var backdrop: CGFloat { min(max(grown, 0), 1) * backdropStart }
    var photoOpacity: CGFloat { landless ? min(max(grown, 0), 1) : 1 }
    var radius: CGFloat { thumbRadius + (0 - thumbRadius) * min(max(grown, 0), 1) }
}

extension EnvironmentValues {
    /// The view's page is what you're looking at: not a hidden page (Matte keeps them alive),
    /// not covered by a profile, a story, the story editor or an opened post. Anything that
    /// plays sound pauses when this turns false and carries on when it's back.
    @Entry var onScreen: Bool = true
    @Entry var photoFlight: PhotoFlight? = nil
    /// Starts loading a hovered post's comments (set by the page that owns the posts).
    @Entry var prewarmPost: ((Media) -> Void)? = nil
}

/// The flying photo and the backdrop darkening behind it. Draws nothing when idle.
struct PhotoFlightOverlay: View {
    let flight: PhotoFlight
    /// The backdrop the viewer uses, so the hand-off is seamless.
    var backdropOpacity: CGFloat = 0.82

    var body: some View {
        if let media = flight.media {
            ZStack(alignment: .topLeading) {
                Color.black.opacity(backdropOpacity * flight.backdrop)
                    .allowsHitTesting(false)
                FlightPhoto(media: media, decoded: flight.image)
                    .frame(width: max(flight.currentRect.width, 1), height: max(flight.currentRect.height, 1))
                    .clipShape(RoundedRectangle(cornerRadius: flight.radius, style: .continuous))
                    .position(x: flight.center.x, y: flight.center.y)
                    .opacity(flight.photoOpacity)
            }
            .allowsHitTesting(false)
        }
    }
}

/// The photo in flight: the full-size decode when ready, the tile's image until then. It never
/// reloads as its frame changes (a size-bucketed image view would, every few frames).
private struct FlightPhoto: View {
    let media: Media
    let decoded: CGImage?
    @State private var low: CGImage?

    var body: some View {
        ZStack {
            Color.black
            if let image = decoded ?? low {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .task(id: media.pk) {
            let first = media.children.first ?? media
            guard decoded == nil, let url = first.image(minWidth: 480) else { return }
            low = await ImagePipeline.shared.image(for: url, maxPixel: 640)
        }
    }
}

extension View {
    /// A page that opens posts with the flight: names the coordinate space, tracks its size, and
    /// draws the flight above everything (including the viewer).
    func photoFlightHost(_ flight: PhotoFlight) -> some View {
        self
            .coordinateSpace(.named(PhotoFlight.space))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { flight.hostSize = $0 }
            .overlay { PhotoFlightOverlay(flight: flight) }
            .environment(\.photoFlight, flight)
    }

    /// A tile the flight starts from and lands in; hidden while its photo is in flight. Its
    /// full-size photo is downloaded when it appears and decoded when hovered (a click is likely).
    func photoFlightTile(_ media: Media, radius: CGFloat = 0) -> some View {
        modifier(FlightTile(media: media, radius: radius))
    }
}

private struct FlightTile: ViewModifier {
    let media: Media
    let radius: CGFloat
    private var pk: String { media.pk }
    @Environment(\.photoFlight) private var flight
    @Environment(\.prewarmPost) private var prewarm
    @State private var hoverTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PhotoFlight.space)) } action: { frame in
                flight?.register(pk, frame: frame, radius: radius)
            }
            .onAppear { PhotoFlight.prefetch(media) }
            .onHover { inside in
                hoverTask?.cancel()
                guard inside else { return }
                flight?.warm(media)
                // Resting on a post for a moment: fetch its comments too.
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    if !Task.isCancelled { prewarm?(media) }
                }
            }
            .onDisappear { flight?.forget(pk) }
            .opacity(flight?.isFlying(pk) == true ? 0 : 1)
    }
}
