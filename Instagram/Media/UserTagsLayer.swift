import SwiftUI

/// The people tagged in a photo, as the apps show them: a person button in the bottom-left
/// corner; clicking it shows each name on the photo where they were tagged (click a name for
/// their profile). `fill`: the photo is cropped to the frame (feed cards) rather than fitted.
struct UserTagsLayer: View {
    let media: Media
    var fill = false
    var compact = false
    /// Room under the button (a video's scrub bar).
    var bottomInset: CGFloat = 0
    @State private var shown = false

    private var tags: [UserTag] { media.userTags ?? [] }

    var body: some View {
        if !tags.isEmpty {
            GeometryReader { geo in
                let rect = photoRect(in: geo.size)
                ZStack(alignment: .topLeading) {
                    if shown {
                        ForEach(tags, id: \.self) { tag in
                            TagLabel(tag: tag)
                                .fixedSize()
                                .position(x: clampX(rect.minX + tag.x * rect.width, in: geo.size.width),
                                          y: min(rect.minY + tag.y * rect.height, geo.size.height - 20) + 14)
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .overlay(alignment: .bottomLeading) {
                    Button { withAnimation(.snappy(duration: 0.2)) { shown.toggle() } } label: {
                        Image(systemName: "person.fill")
                            .font(.system(size: compact ? 10 : 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: compact ? 24 : 28, height: compact ? 24 : 28)
                            .background(Circle().fill(.black.opacity(0.6)))
                    }
                    .buttonStyle(.pressable)
                    .help(shown ? "Hide tags" : "Show tagged people")
                    .padding(compact ? 8 : 12)
                    .padding(.bottom, bottomInset)
                }
            }
            .onChange(of: media.pk) { shown = false }
        }
    }

    /// Where the photo is drawn in a frame of `size`: fitted (letterboxed) or filling it.
    private func photoRect(in size: CGSize) -> CGRect {
        let aspect = max(media.aspect, 0.01)
        let frameAspect = size.width / max(size.height, 1)
        let wide = aspect > frameAspect
        let w = (wide != fill) ? size.width : size.height * aspect
        let h = (wide != fill) ? size.width / aspect : size.height
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Keeps a label inside the frame (a tag near the edge would be cut off).
    private func clampX(_ x: CGFloat, in width: CGFloat) -> CGFloat { min(max(x, 50), width - 50) }
}

private struct TagLabel: View {
    let tag: UserTag

    var body: some View {
        VStack(spacing: 0) {
            Triangle().fill(.black.opacity(0.78)).frame(width: 12, height: 6)
            Text(tag.user.username)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.78)))
        }
        .opensProfile(tag.user)
    }

    private nonisolated struct Triangle: Shape {
        func path(in r: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: r.midX, y: r.minY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                p.closeSubpath()
            }
        }
    }
}
