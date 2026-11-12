import SwiftUI
import AVFoundation

/// A post in the Home grid: author, the media at its own shape, counts and two lines of
/// caption. Videos preview silently while hovered; clicking opens the post large.
struct PostTile: View {
    let post: Media
    let width: CGFloat
    var isPreviewing: Bool
    var setPreviewing: (Bool) -> Void
    var open: () -> Void

    @State private var hovering = false
    @State private var hoverTask: Task<Void, Never>?

    /// Instagram's own limits: no taller than 4:5, no wider than 1.91:1.
    static func mediaAspect(_ post: Media) -> CGFloat { min(1.91, max(0.8, post.aspect)) }
    /// Rough tile height for laying out columns before anything is measured.
    static func estimatedHeight(_ post: Media, width: CGFloat) -> CGFloat {
        width / mediaAspect(post) + ((post.caption ?? "").isEmpty ? 70 : 104)
    }

    private var previewVideo: URL? {
        let source = post.children.first ?? post
        return source.isVideo ? source.video(minWidth: width * 2) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            media
            footer
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hovering ? Theme.hover : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.panelStroke))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .contextMenu { PostMenu(media: post, open: open) }
        .onHover { inside in
            hovering = inside
            hoverTask?.cancel()
            guard previewVideo != nil else { return }
            if inside {
                hoverTask = Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    if !Task.isCancelled { setPreviewing(true) }
                }
            } else if isPreviewing {
                setPreviewing(false)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Avatar(url: post.user?.avatar, size: 24)
            Text(post.user?.username ?? "").font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            if post.user?.isVerified == true { VerifiedBadge(size: 10) }
            Spacer(minLength: 0)
            if let t = post.takenAt {
                Text(t.shortAge).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }

    private var media: some View {
        let w = width - 20
        return ZStack {
            RemoteImage(url: post.image(minWidth: w * 2), contentMode: .fill)
            if isPreviewing, let url = previewVideo {
                HoverPreview(url: url)
            }
        }
        .frame(width: w, height: w / Self.mediaAspect(post))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if post.children.count > 1 {
                badge("square.on.square.fill", text: "\(post.children.count)")
            } else if post.isVideo, !isPreviewing {
                badge("play.fill", text: nil)
            }
        }
    }

    private func badge(_ symbol: String, text: String?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if let text { Text(text) }
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Capsule().fill(.black.opacity(0.45)))
        .padding(8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            PostActionBar(media: post, size: 20, onComment: open)
            if let caption = post.caption, !caption.isEmpty {
                Text(caption).font(.system(size: 12.5)).lineLimit(2).foregroundStyle(.primary.opacity(0.85))
            }
        }
    }
}

/// A silent looping preview while the pointer rests on a video post.
private struct HoverPreview: View {
    let url: URL
    @State private var video: LoopingVideo?

    var body: some View {
        ZStack {
            if let video { PlayerLayerView(player: video.player, gravity: .resizeAspectFill) }
        }
        .allowsHitTesting(false)
        .onAppear {
            let v = LoopingVideo(url: url, muted: true)
            v.play()
            video = v
        }
        .onDisappear {
            video?.tearDown()
            video = nil
        }
    }
}

struct MuteButton: View {
    @State private var sound = SoundSetting.shared
    var body: some View {
        Button { sound.muted.toggle() } label: {
            Image(systemName: sound.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.black.opacity(0.55)))
        }
        .buttonStyle(.pressable)
        .help(sound.muted ? "Unmute" : "Mute")
    }
}
