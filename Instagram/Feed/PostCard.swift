import SwiftUI
import AVFoundation

struct PostCard: View {
    let post: Media
    var isPlaying: Bool
    var setPlaying: (Bool) -> Void

    @State private var page = 0
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.padding(.horizontal, 14)
            MediaCarousel(post: post, page: $page, isActive: isPlaying, setActive: setPlaying)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 6)
            footer.padding(.horizontal, 14)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Avatar(url: post.user?.avatar, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(post.user?.username ?? "").font(.system(size: 13, weight: .semibold))
                    if post.user?.isVerified == true { VerifiedBadge(size: 11) }
                    if let t = post.takenAt {
                        Text("· \(t.shortAge)").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            if let url = post.webURL {
                ChromeButton("Open on Instagram", symbol: "arrow.up.right") { NSWorkspace.shared.open(url) }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                if let likes = post.likeCount, likes > 0 {
                    Label(likes.compact, systemImage: post.hasLiked ? "heart.fill" : "heart")
                        .foregroundStyle(post.hasLiked ? AnyShapeStyle(Theme.like) : AnyShapeStyle(.primary))
                }
                if let comments = post.commentCount, comments > 0 {
                    Label(comments.compact, systemImage: "bubble.right")
                }
                Spacer()
                if post.children.count > 1 {
                    PageDots(count: post.children.count, current: page)
                }
            }
            .font(.system(size: 13, weight: .medium))
            if let caption = post.caption, !caption.isEmpty {
                (Text(post.user?.username ?? "").fontWeight(.semibold) + Text("  ") + Text(caption))
                    .font(.system(size: 13))
                    .lineLimit(expanded ? nil : 2)
                    .textSelection(.enabled)
                    .onTapGesture { expanded.toggle() }
            }
        }
    }
}

/// A post's media: one image or video, or a carousel paged with arrows.
struct MediaCarousel: View {
    let post: Media
    @Binding var page: Int
    var isActive: Bool
    var setActive: (Bool) -> Void
    @State private var hovering = false

    private var items: [Media] { post.children.isEmpty ? [post] : post.children }
    /// Instagram's own limits: no taller than 4:5, no wider than 1.91:1.
    private var aspect: CGFloat { min(1.91, max(0.8, (items.first ?? post).aspect)) }

    var body: some View {
        let current = items[min(page, items.count - 1)]
        ZStack {
            if current.isVideo {
                InlineVideo(media: current, isActive: isActive, setActive: setActive)
                    .id(current.pk)
            } else {
                RemoteImage(url: current.image(minWidth: 1080), contentMode: .fill)
            }
            if items.count > 1, hovering {
                HStack {
                    if page > 0 { arrow("chevron.left") { page -= 1 } }
                    Spacer()
                    if page < items.count - 1 { arrow("chevron.right") { page += 1 } }
                }
                .padding(10)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(Theme.placeholder)
        .onHover { hovering = $0 }
        .onChange(of: page) { setActive(false) }
    }

    private func arrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.85)))
        }
        .buttonStyle(.pressable)
    }
}

/// A video in a post: the cover until clicked, then plays (one at a time across the feed).
struct InlineVideo: View {
    let media: Media
    var isActive: Bool
    var setActive: (Bool) -> Void
    @State private var video: LoopingVideo?
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack {
            RemoteImage(url: media.image(minWidth: 1080), contentMode: .fill)
            if let video, isActive {
                PlayerLayerView(player: video.player, gravity: .resizeAspectFill)
            }
            if !isActive {
                Image(systemName: "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { setActive(!isActive) }
        .overlay(alignment: .bottomTrailing) {
            if isActive { MuteButton().padding(10) }
        }
        .onChange(of: isActive, initial: true) { _, active in
            if active {
                if video == nil, let url = media.video(minWidth: 640) {
                    video = LoopingVideo(url: url, muted: SoundSetting.shared.muted)
                }
                video?.play()
            } else {
                video?.tearDown()
                video = nil
            }
        }
        .onDisappear {
            video?.tearDown()
            video = nil
            if isActive { setActive(false) }
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

struct PageDots: View {
    let count: Int
    let current: Int
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<min(count, 10), id: \.self) { i in
                Circle().fill(i == current ? Theme.link : Color.primary.opacity(0.2)).frame(width: 6, height: 6)
            }
        }
    }
}
