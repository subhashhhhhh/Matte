import SwiftUI
import AVFoundation

/// One post or reel opened large: the media (fetched by id when we only have a preview, as
/// with a reel shared in a DM) and its comments, a page at a time.
@Observable
final class MediaDetailModel: Identifiable {
    let pk: String
    private(set) var media: Media?
    private(set) var comments: [IGComment] = []
    private(set) var loadingMedia = false
    private(set) var loadingComments = false
    private(set) var failed = false
    /// Off for a photo or video sent straight into a chat: there is nothing to fetch.
    let isRemote: Bool
    /// Where "Open on Instagram" goes when the media itself has no link yet.
    let fallbackURL: URL?

    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var hasMore = true
    @ObservationIgnored private let client: IGClient?
    @ObservationIgnored private var started = false

    var id: String { pk }
    var webURL: URL? { media?.webURL ?? fallbackURL }

    init(pk: String, media: Media? = nil, client: IGClient?, fallbackURL: URL? = nil) {
        self.pk = pk
        self.media = media
        self.client = client
        self.isRemote = client != nil
        self.fallbackURL = fallbackURL
    }

    /// A photo or video sent in a chat, shown in the same viewer (no comments).
    convenience init(attachment a: DMAttachment) {
        var m = Media(id: a.id ?? a.url?.absoluteString ?? UUID().uuidString, pk: a.id ?? UUID().uuidString,
                      kind: a.kind == .video ? .video : .image)
        let w = max(a.width, 1), h = max(a.height, 1)
        m.width = w
        m.height = h
        if a.kind == .video {
            if let url = a.url { m.videos = [Rendition(url: url, width: w, height: h)] }
            if let p = a.preview { m.images = [Rendition(url: p, width: w, height: h)] }
        } else if let url = a.url ?? a.preview {
            m.images = [Rendition(url: url, width: w, height: h)]
        }
        self.init(pk: m.pk, media: m, client: nil)
    }

    func start() async {
        guard !started, let client else { return }
        started = true
        if media == nil || (media?.kind != .carousel && media?.images.isEmpty == true) {
            loadingMedia = true
            do { media = try await client.mediaInfo(pk: pk) } catch {
                if !(error is CancellationError) { failed = true }
            }
            loadingMedia = false
        }
        await loadMoreComments()
    }

    func loadMoreComments() async {
        guard let client, hasMore, !loadingComments else { return }
        loadingComments = true
        defer { loadingComments = false }
        do {
            let page = try await client.comments(pk: pk, cursor: cursor)
            let known = Set(comments.map(\.id))
            comments += page.items.filter { !known.contains($0.id) }
            cursor = page.cursor
            hasMore = page.hasMore
        } catch {
            hasMore = false
        }
    }

    var canLoadMoreComments: Bool { hasMore && isRemote }
}

// MARK: - Stage

/// The media itself, as large as the space allows: a video that plays on its own (one player,
/// torn down when it leaves), a photo, or a carousel paged with arrows or ←/→.
struct MediaStage: View {
    let media: Media
    var cornerRadius: CGFloat = 12
    @State private var page = 0

    private var items: [Media] { media.children.isEmpty ? [media] : media.children }

    var body: some View {
        let current = items[min(page, items.count - 1)]
        ZStack {
            Color.black
            if current.isVideo, let url = current.video(minWidth: 720) {
                StageVideo(url: url, cover: current.image(minWidth: 720)).id(current.pk + url.absoluteString)
            } else {
                RemoteImage(url: current.image(minWidth: 1080), contentMode: .fit).id(current.pk)
            }
            if items.count > 1 {
                HStack {
                    if page > 0 { pageArrow("chevron.left") { page -= 1 } }
                    Spacer()
                    if page < items.count - 1 { pageArrow("chevron.right") { page += 1 } }
                }
                .padding(10)
                VStack {
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(0..<min(items.count, 12), id: \.self) { i in
                            Circle().fill(.white.opacity(i == page ? 1 : 0.4)).frame(width: 6, height: 6)
                        }
                    }
                    .padding(10)
                }
                .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onChange(of: media.pk) { page = 0 }
    }

    private func pageArrow(_ symbol: String, action: @escaping () -> Void) -> some View {
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

/// A video that starts when shown and lets go of its player when it leaves.
struct StageVideo: View {
    let url: URL
    var cover: URL?
    @State private var video: LoopingVideo?
    @State private var sound = SoundSetting.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: cover, contentMode: .fit)
            if let video {
                PlayerLayerView(player: video.player, gravity: .resizeAspect)
                    .contentShape(Rectangle())
                    .onTapGesture { video.toggle() }
                if !video.isPlaying {
                    Image(systemName: "play.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
                ScrubBar(video: video)
            }
        }
        .overlay(alignment: .topTrailing) { MuteButton().padding(10) }
        .onAppear {
            let v = LoopingVideo(url: url, muted: sound.muted)
            v.play()
            video = v
        }
        .onDisappear {
            video?.tearDown()
            video = nil
            MemoryRelief.soon()
        }
        .onChange(of: sound.muted) { video?.isMuted = sound.muted }
    }
}

/// A thin progress line you can click or drag to seek.
struct ScrubBar: View {
    let video: LoopingVideo
    @State private var hovering = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(.white.opacity(hovering ? 0.3 : 0.15)).frame(height: hovering ? 5 : 2)
                Rectangle().fill(.white.opacity(0.9)).frame(width: g.size.width * video.progress, height: hovering ? 5 : 2)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                video.seek(fraction: min(1, max(0, v.location.x / max(g.size.width, 1))))
            })
        }
        .frame(height: 16)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Details

/// Author, caption, counts and the comments, scrolling as one column.
struct MediaDetailsColumn: View {
    let model: MediaDetailModel
    var showsHeader = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let media = model.media {
                    if showsHeader { author(media) }
                    if let caption = media.caption, !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    stats(media)
                } else if model.loadingMedia {
                    Spinner(size: 16).frame(maxWidth: .infinity).padding(20)
                }
                if model.isRemote {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                    if model.comments.isEmpty, !model.loadingComments {
                        Text("No comments").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                    ForEach(model.comments) { CommentRow(comment: $0) }
                    if model.loadingComments {
                        Spinner(size: 14).frame(maxWidth: .infinity).padding(8)
                    } else if model.canLoadMoreComments {
                        Color.clear.frame(height: 1).onAppear { Task { await model.loadMoreComments() } }
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.never)
    }

    private func author(_ media: Media) -> some View {
        HStack(spacing: 10) {
            Avatar(url: media.user?.avatar, size: 34)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(media.user?.username ?? "").font(.system(size: 13.5, weight: .semibold))
                    if media.user?.isVerified == true { VerifiedBadge(size: 11) }
                }
                if let t = media.takenAt {
                    Text(t.shortAge).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func stats(_ media: Media) -> some View {
        HStack(spacing: 16) {
            if let n = media.likeCount, n > 0 {
                Label(n.compact, systemImage: media.hasLiked ? "heart.fill" : "heart")
                    .foregroundStyle(media.hasLiked ? AnyShapeStyle(Theme.like) : AnyShapeStyle(.primary))
            }
            if let n = media.commentCount, n > 0 { Label(n.compact, systemImage: "bubble.right") }
            if let n = media.viewCount, n > 0 { Label(n.compact, systemImage: "play") }
        }
        .font(.system(size: 12.5, weight: .medium))
    }
}

struct CommentRow: View {
    let comment: IGComment

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(url: comment.user?.avatar, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.user?.username ?? "").font(.system(size: 12.5, weight: .semibold))
                    if let t = comment.createdAt {
                        Text(t.shortAge).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                Text(comment.text)
                    .font(.system(size: 12.5))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if comment.likeCount > 0 || comment.replyCount > 0 {
                    HStack(spacing: 10) {
                        if comment.likeCount > 0 { Label(comment.likeCount.compact, systemImage: "heart") }
                        if comment.replyCount > 0 { Text("\(comment.replyCount) \(comment.replyCount == 1 ? "reply" : "replies")") }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
