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
    @Environment(AppModel.self) private var app
    /// The post's song, once known (asked when you rest on it).
    @State private var track: MusicTrack?
    @State private var musicTask: Task<Void, Never>?
    @State private var holder = UUID()
    @State private var music = PostMusic.shared
    @Environment(\.onScreen) private var onScreen
    /// The carousel photo showing (shared with the opened post).
    @State private var pages = CarouselPages.shared
    @State private var likeBurst = 0

    /// Instagram's own limits: no taller than 4:5, no wider than 1.91:1.
    static func mediaAspect(_ post: Media) -> CGFloat { min(1.91, max(0.8, post.aspect)) }
    /// Rough tile height for laying out columns before anything is measured.
    static func estimatedHeight(_ post: Media, width: CGFloat) -> CGFloat {
        width / mediaAspect(post) + ((post.caption ?? "").isEmpty ? 70 : 104)
    }

    private var page: Int { min(pages.page(post.pk), max(post.children.count - 1, 0)) }
    private var pageBinding: Binding<Int> {
        Binding { page } set: { pages.set($0, for: post.pk) }
    }

    private var previewVideo: URL? {
        let source = post.shownItem
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
        .scaleEffect(hovering && !Motion.reduced ? 1.006 : 1)
        .shadow(color: .black.opacity(hovering ? 0.18 : 0), radius: hovering ? 14 : 0, y: hovering ? 6 : 0)
        .animation(.easeOut(duration: 0.25), value: hovering)
        .contentShape(Rectangle())
        // Click opens the post; a quick double-click likes it instead.
        .doubleTapToLike(single: open) {
            app.actions?.like(post)
            likeBurst += 1
        }
        .contextMenu { PostMenu(media: post, open: open) }
        .onAppear { if track == nil { track = PostMusic.shared.cached(post.pk) } }
        .onDisappear { musicTask?.cancel(); PostMusic.shared.release(holder) }
        .onChange(of: onScreen) { if !onScreen { musicTask?.cancel(); PostMusic.shared.release(holder) } }
        // Paged onto a video while resting on the card: preview it (and stop on a photo).
        .onChange(of: page) {
            if hovering, previewVideo != nil { setPreviewing(true) } else if isPreviewing, previewVideo == nil { setPreviewing(false) }
            // A carousel's song gives way to a video page's own sound, and comes back on a photo.
            if previewVideo != nil { musicTask?.cancel(); PostMusic.shared.release(holder) } else if hovering { hoverMusic(true) }
            prefetchNeighbours()
        }
        .onHover { inside in
            hovering = inside
            hoverTask?.cancel()
            if inside, post.children.count > 1 { prefetchNeighbours() }
            hoverMusic(inside)
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
            VStack(alignment: .leading, spacing: 2) {
                AuthorLine(media: post, avatarSize: 24, fontSize: 12.5)
                // Named by the feed straight away; the audio is asked for when you rest on it.
                if let track {
                    MusicLine(track: track, fontSize: 11, playing: music.playingPk == post.pk)
                        .padding(.leading, 32)
                        .transition(.opacity)
                } else if let song = post.songName {
                    MusicLine(title: song.title, artist: song.artist, fontSize: 11)
                        .padding(.leading, 32)
                }
            }
            Spacer(minLength: 0)
            if let t = post.takenAt {
                Text(t.shortAge).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
        .animation(.easeOut(duration: 0.2), value: track)
    }

    /// Resting on a photo post plays its song (asked once), as the feed plays it on the phone.
    private func hoverMusic(_ inside: Bool) {
        musicTask?.cancel()
        guard inside else { PostMusic.shared.release(holder); return }
        guard previewVideo == nil, !post.isVideo else { return }
        musicTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let found = await PostMusic.shared.track(for: post, client: app.client)
            guard !Task.isCancelled else { return }
            track = found
            if let found, hovering, onScreen { PostMusic.shared.play(found, for: post.pk, holder: holder) }
        }
    }

    private var media: some View {
        let w = width - 20
        let items = post.children
        return ZStack {
            if items.count > 1 {
                CarouselPager(count: items.count, page: pageBinding) { i in
                    ZStack {
                        RemoteImage(url: items[i].image(minWidth: w * 2), contentMode: .fill)
                        if i == page, isPreviewing, let url = previewVideo {
                            HoverPreview(url: url).id(url)
                        }
                        UserTagsLayer(media: items[i], fill: true, compact: true)
                    }
                }
            } else {
                RemoteImage(url: post.image(minWidth: w * 2), contentMode: .fill)
                if isPreviewing, let url = previewVideo {
                    HoverPreview(url: url)
                }
                UserTagsLayer(media: post, fill: true, compact: true)
            }
        }
        .frame(width: w, height: w / Self.mediaAspect(post))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .photoFlightTile(post, radius: 10)
        .overlay { if post.children.count > 1 { carouselChrome } }
        .overlay { HeartBurst(trigger: likeBurst, size: min(90, w * 0.3)) }
        // Beside the tags button when the photo showing has tags.
        .overlay(alignment: .bottomLeading) {
            RepostBubbles(media: post, compact: true).padding(.leading, post.shownItem.userTags == nil ? 0 : 34)
        }
        .overlay(alignment: .topTrailing) {
            if post.children.count > 1 {
                badge("square.on.square.fill", text: page > 0 ? "\(page + 1)/\(post.children.count)" : "\(post.children.count)")
            } else if post.isVideo, !isPreviewing {
                badge("play.fill", text: nil)
            }
        }
        // Sound on: the hovered video, or a photo post's song (carousels too).
        .overlay(alignment: .bottomTrailing) {
            if isPreviewing && previewVideo != nil || music.playingPk == post.pk {
                MuteButton().padding(8).transition(.opacity)
            }
        }
    }

    /// Arrows while the pointer is on the card (for a mouse), and the page dots.
    private var carouselChrome: some View {
        let count = post.children.count
        return ZStack {
            if hovering {
                HStack {
                    if page > 0 { pageArrow("chevron.left") { pageBinding.wrappedValue = page - 1 } }
                    Spacer()
                    if page < count - 1 { pageArrow("chevron.right") { pageBinding.wrappedValue = page + 1 } }
                }
                .padding(.horizontal, 8)
                .transition(.opacity)
            }
            VStack {
                Spacer()
                HStack(spacing: 4) {
                    ForEach(0..<min(count, 12), id: \.self) { i in
                        Circle().fill(.white.opacity(i == page ? 1 : 0.45)).frame(width: 5, height: 5)
                    }
                }
                .shadow(color: .black.opacity(0.35), radius: 2)
                .padding(.bottom, 9)
            }
            .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private func pageArrow(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.white.opacity(0.85)))
        }
        .buttonStyle(.pressable)
    }

    /// The photos either side of the one showing, so a swipe never lands on a blank.
    private func prefetchNeighbours() {
        let urls = [page - 1, page + 1].filter { post.children.indices.contains($0) }
            .compactMap { post.children[$0].image(minWidth: width * 2) }
        Task { await ImagePipeline.shared.prefetch(urls) }
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
            LikedByLine(media: post, avatarSize: 18, fontSize: 12)
            if let caption = post.caption, !caption.isEmpty {
                Text(caption).font(.system(size: 12.5)).lineLimit(2).foregroundStyle(.primary.opacity(0.85))
            }
        }
    }
}

/// A silent looping preview while the pointer rests on a video post.
struct HoverPreview: View {
    let url: URL
    /// With sound (the app's sound setting), as the phone's feed plays it; muted in grids.
    var sound = true
    @State private var video: LoopingVideo?
    @State private var setting = SoundSetting.shared
    @Environment(\.onScreen) private var onScreen

    var body: some View {
        ZStack {
            if let video { PlayerLayerView(player: video.player, gravity: .resizeAspectFill) }
        }
        .allowsHitTesting(false)
        .onAppear {
            let v = LoopingVideo(url: url, muted: !sound || setting.muted)
            if onScreen { v.play() }
            video = v
        }
        .onChange(of: setting.muted) { video?.isMuted = !sound || setting.muted }
        .onChange(of: onScreen) { if onScreen { video?.play() } else { video?.pause() } }
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
