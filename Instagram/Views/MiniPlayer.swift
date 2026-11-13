import SwiftUI

/// The post or reel you were looking at when you went to a profile: it shrinks from where it
/// was into the bottom-right corner and keeps playing. Click it to open it again; hover for ✕;
/// drag it to another corner.
struct MiniPlayer: View {
    let mini: AppModel.MiniPost
    @Environment(AppModel.self) private var app
    @State private var docked = false
    @State private var corner = Corner.bottomTrailing
    @State private var drag: CGSize = .zero
    @State private var hovering = false
    /// Growing back to full size (then the post's viewer takes over in the same place).
    @State private var expanding = false

    enum Corner: CaseIterable { case topLeading, topTrailing, bottomLeading, bottomTrailing }

    private static let inset: CGFloat = 20
    private static var dock: Animation { Motion.reduced ? .easeInOut(duration: 0.2) : .spring(response: 0.48, dampingFraction: 0.84) }

    var body: some View {
        GeometryReader { geo in
            if let media = mini.model.media {
                let target = rect(corner, in: geo.size, aspect: media.aspect)
                let full = PostLightbox.stageRect(in: geo.size, media: media)
                let r = expanding ? full : docked ? target : mini.from
                // The viewer's backdrop, darkening as it grows (the viewer has the same one).
                Color.black.opacity(expanding ? 0.82 : 0)
                    .allowsHitTesting(false)
                MediaStage(media: media, cornerRadius: docked && !expanding ? 14 : 0, chrome: false)
                    .frame(width: r.width, height: r.height)
                    .overlay(alignment: .topLeading) {
                        if hovering, docked, !expanding {
                            Button { expand() } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 26, height: 26).background(Circle().fill(.black.opacity(0.6)))
                            }
                            .buttonStyle(.pressable)
                            .help("Open full size")
                            .padding(8)
                            .transition(.opacity)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if hovering, docked, !expanding {
                            Button { close() } label: {
                                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 26, height: 26).background(Circle().fill(.black.opacity(0.6)))
                            }
                            .buttonStyle(.pressable)
                            .padding(8)
                            .transition(.opacity)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if hovering, docked, !expanding, let user = media.user {
                            Text(user.username).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.6), radius: 3)
                                .padding(10)
                                .transition(.opacity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: docked && !expanding ? 14 : 0, style: .continuous))
                    .shadow(color: .black.opacity(docked && !expanding ? 0.45 : 0), radius: 24, y: 10)
                    .scaleEffect(hovering && drag == .zero && !expanding ? 1.03 : 1)
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovering = inside } }
                    .onTapGesture { expand() }
                    .gesture(DragGesture(minimumDistance: 4)
                        .onChanged { drag = $0.translation }
                        .onEnded { v in
                            let end = CGPoint(x: target.midX + v.predictedEndTranslation.width, y: target.midY + v.predictedEndTranslation.height)
                            withAnimation(Self.dock) {
                                corner = Self.nearest(end, in: geo.size)
                                drag = .zero
                            }
                        })
                    .position(x: r.midX + drag.width, y: r.midY + drag.height)
                    .help("Click to open again · drag to move")
                    // Next frame, so it's drawn where the post was before it moves.
                    .onAppear { DispatchQueue.main.async { withAnimation(Self.dock) { docked = true } } }
            }
        }
        .onKeyPress(.escape) { close(); return .handled }
    }

    /// Grows back to where the post's viewer shows it, then hands over (same player, no gap).
    private func expand() {
        guard !expanding else { return }
        hovering = false
        withAnimation(Self.dock, completionCriteria: .logicallyComplete) { expanding = true } completion: {
            app.expandMini()
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.18)) { app.miniPost = nil }
    }

    /// Its place in a corner: about 260 points on its longer side, in the post's own shape.
    private func rect(_ corner: Corner, in size: CGSize, aspect: CGFloat) -> CGRect {
        let a = min(1.91, max(0.5, aspect))
        let long: CGFloat = size.width > 1200 ? 300 : 250
        let w = a >= 1 ? long : long * a
        let h = a >= 1 ? long / a : long
        let x = (corner == .topLeading || corner == .bottomLeading) ? Self.inset : size.width - w - Self.inset
        let y = (corner == .topLeading || corner == .topTrailing) ? Self.inset : size.height - h - Self.inset
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func nearest(_ p: CGPoint, in size: CGSize) -> Corner {
        let left = p.x < size.width / 2, top = p.y < size.height / 2
        switch (left, top) {
        case (true, true): return .topLeading
        case (false, true): return .topTrailing
        case (true, false): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }
}
