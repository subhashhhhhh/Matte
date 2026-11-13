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
        if media == nil || media?.needsFullInfo == true {
            // A grid's preview (a reel without its video, a carousel without its photos) stays on
            // screen while the whole post loads, so the photo flight lands on something.
            let shown = media
            loadingMedia = true
            do {
                var full = try await client.mediaInfo(pk: pk)
                if full.suggested == nil { full.suggested = shown?.suggested }
                media = full
            } catch {
                if !(error is CancellationError), shown == nil { failed = true }
            }
            loadingMedia = false
        }
        await loadMoreComments()
        if Task.isCancelled, comments.isEmpty { started = false }
        #if DEBUG
        // `-IGGifFirst YES`: GIF comments first (to check how they draw).
        if UserDefaults.standard.bool(forKey: "IGGifFirst") { comments.sort { ($0.gif != nil) && ($1.gif == nil) } }
        // `-IGOpenReplies YES`: open the first comment's replies (screenshots).
        if UserDefaults.standard.bool(forKey: "IGOpenReplies"), let c = comments.first(where: { $0.replyCount > 0 }) {
            await loadReplies(c)
        }
        #endif
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
            let cancelled = error is CancellationError || (error as? URLError)?.code == .cancelled
            if !cancelled { hasMore = false }
        }
    }

    var canLoadMoreComments: Bool { hasMore && isRemote }

    // MARK: Cache

    /// Posts opened (or hovered) recently, with their comments: reopening one is instant.
    private static var recent: [String: MediaDetailModel] = [:]
    private static var order: [String] = []

    /// Shows an edited caption wherever the post is open or cached.
    static func updateCaption(pk: String, text: String) {
        recent[pk]?.media?.caption = text.isEmpty ? nil : text
    }

    /// Forgets every cached post (sign-out: the next account must not see this one's).
    static func clearCache() {
        recent = [:]
        order = []
    }

    /// The cached model for `pk`, or a new one (kept for the next 40 posts).
    static func cached(pk: String, media: Media? = nil, client: IGClient?, fallbackURL: URL? = nil) -> MediaDetailModel {
        // Only reuse a post loaded by the same signed-in client (never another account's).
        if let hit = recent[pk], hit.client === client {
            order.removeAll { $0 == pk }
            order.append(pk)
            if hit.media == nil, let media { hit.media = media }
            return hit
        }
        let model = MediaDetailModel(pk: pk, media: media, client: client, fallbackURL: fallbackURL)
        recent[pk] = model
        order.append(pk)
        while order.count > 40 { recent[order.removeFirst()] = nil }
        return model
    }

    // MARK: Replies, likes, posting

    /// Loaded replies by parent comment id (a parent is "open" once it has an entry).
    private(set) var replies: [String: [IGComment]] = [:]
    private(set) var loadingReplies: Set<String> = []
    @ObservationIgnored private var replyCursors: [String: String] = [:]
    @ObservationIgnored private var replyMore: [String: Bool] = [:]
    /// The comment being answered in the composer.
    var replyingTo: IGComment?
    var draft = ""
    private(set) var posting = false
    @ObservationIgnored weak var app: AppModel?

    func hasMoreReplies(_ c: IGComment) -> Bool {
        guard let loaded = replies[c.id] else { return c.replyCount > 0 }
        return replyMore[c.id] ?? (loaded.count < c.replyCount)
    }

    func toggleReplies(_ c: IGComment) {
        if replies[c.id] != nil, !hasMoreReplies(c) { replies[c.id] = nil; return }
        Task { await loadReplies(c) }
    }

    func hideReplies(_ c: IGComment) { replies[c.id] = nil; replyCursors[c.id] = nil; replyMore[c.id] = nil }

    func loadReplies(_ c: IGComment) async {
        guard let client, !loadingReplies.contains(c.id) else { return }
        loadingReplies.insert(c.id)
        defer { loadingReplies.remove(c.id) }
        do {
            let page = try await client.replies(media: pk, comment: c.id, cursor: replyCursors[c.id])
            let known = Set((replies[c.id] ?? []).map(\.id))
            replies[c.id, default: []] += page.items.filter { !known.contains($0.id) }
            replyCursors[c.id] = page.cursor
            replyMore[c.id] = page.hasMore
        } catch {
            app?.report(error)
        }
    }

    /// Likes or unlikes a comment at once, undone if Instagram refuses.
    func toggleLike(_ c: IGComment) {
        guard let client else { return }
        let liked = !c.liked
        update(c.id) { $0.liked = liked; $0.likeCount = max(0, $0.likeCount + (liked ? 1 : -1)) }
        Task {
            do { try await client.setCommentLiked(liked, comment: c.id) } catch {
                update(c.id) { $0.liked = !liked; $0.likeCount = max(0, $0.likeCount + (liked ? -1 : 1)) }
                app?.report(error)
            }
        }
    }

    /// Whether the comment is yours (only those can be deleted here).
    func isMine(_ c: IGComment) -> Bool {
        guard let me = app?.viewerId, !c.id.hasPrefix("local-") else { return false }
        return c.user?.id == me
    }

    /// Deletes one of your comments: it goes at once and comes back if Instagram refuses.
    func delete(_ c: IGComment) {
        guard let client, isMine(c) else { return }
        let parent = c.parentId
        let saved = (comments, replies)
        remove(c.id, parent: parent)
        if parent == nil { replies[c.id] = nil }
        if let parent, let i = comments.firstIndex(where: { $0.id == parent }) {
            comments[i].replyCount = max(0, comments[i].replyCount - 1)
        }
        Task {
            do { try await client.deleteComment(c.id, media: pk) } catch {
                (comments, replies) = saved
                app?.report(error)
            }
        }
    }

    private func update(_ id: String, _ change: (inout IGComment) -> Void) {
        if let i = comments.firstIndex(where: { $0.id == id }) { change(&comments[i]); return }
        for (parent, list) in replies {
            if let i = list.firstIndex(where: { $0.id == id }) { change(&replies[parent]![i]); return }
        }
    }

    /// Posts the draft as a comment, or as a reply to `replyingTo`. It shows at once.
    func post() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !text.isEmpty, !posting else { return }
        posting = true
        defer { posting = false }
        // Replies to a reply go to the top comment, as on Instagram.
        let parent = replyingTo.map { $0.parentId ?? $0.id }
        var local = IGComment(id: "local-\(UUID().uuidString)", user: app?.me, text: text, createdAt: .now)
        local.parentId = parent
        if let parent { replies[parent, default: []].append(local) } else { comments.insert(local, at: 0) }
        draft = ""
        replyingTo = nil
        do {
            let made = try await client.postComment(text, media: pk, replyTo: parent)
            if var made {
                made.parentId = parent
                if made.user == nil { made.user = app?.me }
                replace(local.id, with: made, parent: parent)
            }
            if parent != nil, let i = comments.firstIndex(where: { $0.id == parent }) { comments[i].replyCount += 1 }
        } catch {
            remove(local.id, parent: parent)
            draft = text
            app?.report(error)
        }
    }

    private func replace(_ id: String, with c: IGComment, parent: String?) {
        if let parent, let i = replies[parent]?.firstIndex(where: { $0.id == id }) { replies[parent]![i] = c }
        else if let i = comments.firstIndex(where: { $0.id == id }) { comments[i] = c }
    }

    private func remove(_ id: String, parent: String?) {
        if let parent { replies[parent]?.removeAll { $0.id == id } } else { comments.removeAll { $0.id == id } }
    }
}

// MARK: - Stage

/// The media itself, as large as the space allows: a video that plays on its own (one player,
/// torn down when it leaves), a photo, or a carousel paged with arrows or ←/→.
struct MediaStage: View {
    let media: Media
    var cornerRadius: CGFloat = 12
    /// The first photo, already decoded (handed over by the photo flight), so it shows at once.
    var initialImage: CGImage? = nil
    /// Arrows, the song chip: off in the mini player (it's too small; the song still plays).
    var chrome = true
    @State private var pages = CarouselPages.shared
    /// Shared with the feed card (and the mini player): opens on the photo you paged to.
    private var page: Int {
        get { min(pages.page(media.pk), max(items.count - 1, 0)) }
        nonmutating set { pages.set(newValue, for: media.pk) }
    }
    private var pageBinding: Binding<Int> { Binding { page } set: { page = $0 } }
    /// The photo it opened on: the flight's decoded photo (`initialImage`) is that one.
    @State private var startPage: Int
    @State private var likeBurst = 0

    init(media: Media, cornerRadius: CGFloat = 12, initialImage: CGImage? = nil, chrome: Bool = true) {
        self.media = media
        self.cornerRadius = cornerRadius
        self.initialImage = initialImage
        self.chrome = chrome
        _startPage = State(initialValue: CarouselPages.shared.page(media.pk))
    }
    @Environment(AppModel.self) private var app
    @State private var track: MusicTrack?
    @State private var holder = UUID()
    @State private var music = PostMusic.shared
    @Environment(\.onScreen) private var onScreen

    private var items: [Media] { media.children.isEmpty ? [media] : media.children }

    var body: some View {
        ZStack {
            Color.black
            if items.count > 1 {
                CarouselPager(count: items.count, page: pageBinding) { i in item(i).overlay { tags(i) } }
            } else {
                item(0).overlay { tags(0) }
            }
            if items.count > 1, chrome {
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
        .overlay { HeartBurst(trigger: likeBurst) }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(alignment: .topLeading) {
            if chrome, track != nil || media.audioName != nil {
                HStack(spacing: 8) {
                    if let track {
                        MusicLine(track: track, fontSize: 12, playing: music.playingPk == media.pk)
                    } else if let audio = media.audioName {
                        // A reel's own audio (the video has its own sound button).
                        MusicLine(title: audio.title, artist: audio.artist, fontSize: 12)
                    }
                    if track != nil { MuteButton() }
                }
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
                .padding(.leading, 12)
                .padding(.trailing, track != nil ? 4 : 12)
                .padding(.vertical, track != nil ? 4 : 8)
                .background(Capsule().fill(.black.opacity(0.45)))
                .padding(12)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: track)
        // A photo post's song plays while it's open.
        .task(id: media.pk) {
            track = nil
            PostMusic.shared.release(holder)
            guard !media.isVideo, media.expiresAt == nil else { return }
            guard let found = await PostMusic.shared.track(for: media, client: app.client), !Task.isCancelled else { return }
            track = found
            if onScreen { PostMusic.shared.play(found, for: media.pk, holder: holder) }
        }
        .onDisappear { PostMusic.shared.release(holder) }
        .onChange(of: onScreen) {
            if !onScreen { PostMusic.shared.release(holder) }
            else if let track { PostMusic.shared.play(track, for: media.pk, holder: holder) }
        }
    }

    /// One photo or video of the post. Only the one showing plays: the photos beside it (kept
    /// by the swipe) show their cover.
    /// Who's tagged in this photo (not in the mini player).
    @ViewBuilder
    private func tags(_ i: Int) -> some View {
        if chrome { UserTagsLayer(media: items[i], bottomInset: items[i].isVideo ? 26 : 0) }
    }

    private var doubleTap: (() -> Void)? {
        guard chrome, media.expiresAt == nil else { return nil }
        return { likeFromDoubleTap() }
    }

    @ViewBuilder
    private func item(_ i: Int) -> some View {
        let current = items[i]
        let initial = i == startPage ? initialImage : nil
        if current.isVideo, i == page, let url = current.video(minWidth: 720) {
            StageVideo(url: url, cover: current.image(minWidth: 720), initialCover: initial, key: current.pk,
                       onDoubleTap: doubleTap)
                .id(current.pk + url.absoluteString)
        } else if chrome, media.expiresAt == nil {
            RemoteImage(url: current.image(minWidth: 1080), contentMode: .fit, initial: initial)
                .id(current.pk)
                .contentShape(Rectangle())
                .doubleTapToLike(like: likeFromDoubleTap)
        } else {
            RemoteImage(url: current.image(minWidth: 1080), contentMode: .fit, initial: initial)
                .id(current.pk)
        }
    }

    /// Double-click on the post: likes it (never unlikes), with the heart.
    private func likeFromDoubleTap() {
        app.actions?.like(media)
        likeBurst += 1
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
    var initialCover: CGImage? = nil
    /// The post's pk: a video handed over under it (`VideoHandoff`) is taken instead of a new one.
    var key: String? = nil
    /// Double-click likes the post (a single click still pauses, a moment later).
    var onDoubleTap: (() -> Void)? = nil
    @State private var video: LoopingVideo?
    @State private var sound = SoundSetting.shared
    @Environment(\.onScreen) private var onScreen
    @State private var resumeOnReturn = false

    private func attach() {
        guard video == nil else { return }
        if let key, let handed = VideoHandoff.shared.claim(key) {
            // The same player, mid-play: no restart, no gap.
            handed.isMuted = sound.muted
            if onScreen { if !handed.isPlaying { handed.play() } } else { handed.pause(); resumeOnReturn = true }
            video = handed
            return
        }
        let v = LoopingVideo(url: url, muted: sound.muted)
        if onScreen { v.play() } else { resumeOnReturn = true }
        video = v
        if let key { VideoHandoff.shared.register(v, key: key) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            RemoteImage(url: cover, contentMode: .fit, initial: initialCover)
            if let video {
                PlayerLayerView(player: video.player, gravity: .resizeAspect)
                    .contentShape(Rectangle())
                    .modifier(PauseOrLike(toggle: video.toggle, like: onDoubleTap))
                if !video.isPlaying {
                    Image(systemName: "play.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }
                ScrubBar(video: video)
            }
        }
        .overlay(alignment: .topTrailing) { MuteButton().padding(10) }
        .onAppear { attach() }
        .onDisappear {
            if let key, let video, VideoHandoff.shared.leave(video, key: key) {
                // Handed to the mini player (or back): it plays on there.
                self.video = nil
                return
            }
            video?.tearDown()
            video = nil
            MemoryRelief.soon()
        }
        .onChange(of: sound.muted) { video?.isMuted = sound.muted }
        // Off screen (another page, a profile, the story editor…): pause; back: carry on.
        .onChange(of: onScreen) {
            // Not while it's being handed to the mini player (or back): it keeps playing.
            if !onScreen { if !VideoHandoff.shared.isExpecting { resumeOnReturn = video?.isPlaying == true; video?.pause() } }
            else if resumeOnReturn { video?.play() }
        }
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
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            comments
            if model.isRemote {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                CommentComposer(model: model)
            }
        }
        .task { model.app = app }
    }

    private var comments: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let media = model.media {
                    if showsHeader { author(media) }
                    if let caption = media.caption, !caption.isEmpty {
                        RichText(caption)
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
                    ForEach(model.comments) { comment in
                        CommentThread(comment: comment, model: model)
                    }
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
            AuthorLine(media: media, avatarSize: 34, fontSize: 13.5, subtitle: media.takenAt?.shortAge)
            Spacer()
            if model.isRemote {
                Menu { PostMenu(media: media) } label: {
                    IGGlyph(icon: .more, size: 20).frame(width: 32, height: 28).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        }
    }

    @ViewBuilder
    private func stats(_ media: Media) -> some View {
        if model.isRemote {
            PostActionBar(media: media, size: 22)
            LikedByLine(media: media)
        }
        if !media.countsHidden, let n = media.viewCount, n > 0 {
            Text("\(n.compact) plays").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// A comment and, once opened, its replies (indented), with "View replies" / "Hide replies".
struct CommentThread: View {
    let comment: IGComment
    let model: MediaDetailModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CommentRow(comment: comment, model: model)
            let loaded = model.replies[comment.id]
            if let loaded {
                ForEach(loaded) { reply in
                    CommentRow(comment: reply, model: model, avatarSize: 22).padding(.leading, 38)
                }
            }
            if comment.replyCount > 0 {
                let open = loaded != nil
                let more = model.hasMoreReplies(comment)
                HStack(spacing: 8) {
                    Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 22, height: 1)
                    Button {
                        if open, !more { model.hideReplies(comment) } else { Task { await model.loadReplies(comment) } }
                    } label: {
                        Text(open && !more ? "Hide replies"
                             : open ? "View more replies"
                             : "View \(comment.replyCount) \(comment.replyCount == 1 ? "reply" : "replies")")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    if model.loadingReplies.contains(comment.id) { Spinner(size: 10) }
                }
                .padding(.leading, 38)
            }
        }
    }
}

struct CommentRow: View {
    let comment: IGComment
    let model: MediaDetailModel
    var avatarSize: CGFloat = 28
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(url: comment.user?.avatar, size: avatarSize).opensProfile(comment.user)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(comment.user?.username ?? "").font(.system(size: 12.5, weight: .semibold)).opensProfile(comment.user)
                    if let t = comment.createdAt {
                        Text(t.shortAge).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                if !comment.text.isEmpty {
                    RichText(comment.text)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let gif = comment.gif { GIFView(gif: gif) }
                HStack(spacing: 12) {
                    if comment.likeCount > 0 {
                        Button("\(comment.likeCount.compact) \(comment.likeCount == 1 ? "like" : "likes")") {
                            app.showCommentLikers(comment.id)
                        }
                        .buttonStyle(.plain)
                        .help("See who liked this comment")
                    }
                    if !comment.id.hasPrefix("local-") {
                        Button("Reply") { model.replyingTo = comment }
                            .buttonStyle(.plain)
                    }
                    if model.isMine(comment) {
                        Button("Delete") { model.delete(comment) }
                            .buttonStyle(.plain)
                    }
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !comment.id.hasPrefix("local-") {
                Button { model.toggleLike(comment) } label: {
                    IGGlyph(icon: comment.liked ? .heartFilled : .heart, size: 12)
                        .foregroundStyle(comment.liked ? AnyShapeStyle(Theme.like) : AnyShapeStyle(.secondary))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .help(comment.liked ? "Unlike" : "Like")
            }
        }
        .opacity(comment.id.hasPrefix("local-") ? 0.6 : 1)
    }
}

/// A GIF comment: plays its small MP4 silently on a loop while on screen.
struct GIFView: View {
    let gif: IGComment.GIF
    @State private var video: LoopingVideo?

    var body: some View {
        let height: CGFloat = 120
        let width = height * CGFloat(gif.width) / CGFloat(max(gif.height, 1))
        ZStack {
            RemoteImage(url: gif.still, contentMode: .fit)
            if let video { PlayerLayerView(player: video.player, gravity: .resizeAspect) }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            guard let url = gif.mp4 else { return }
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

/// "Add a comment…": Return posts; shows who you're replying to.
struct CommentComposer: View {
    @Bindable var model: MediaDetailModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reply = model.replyingTo {
                HStack(spacing: 6) {
                    Text("Replying to \(reply.user?.username ?? "comment")")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.replyingTo = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 8) {
                TextField(model.replyingTo == nil ? "Add a comment…" : "Add a reply…", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit { Task { await model.post() } }
                let empty = model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                Button("Post") { Task { await model.post() } }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.link.opacity(empty || model.posting ? 0.4 : 1))
                    .disabled(empty || model.posting)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onChange(of: model.replyingTo) {
            if let user = model.replyingTo?.user, !model.draft.contains("@\(user.username)") {
                model.draft = "@\(user.username) " + model.draft
            }
            if model.replyingTo != nil { focused = true }
        }
    }
}

/// A click pauses the video; with a like action, a double-click likes instead.
private struct PauseOrLike: ViewModifier {
    let toggle: () -> Void
    let like: (() -> Void)?

    func body(content: Content) -> some View {
        if let like { content.doubleTapToLike(single: toggle, like: like) } else { content.onTapGesture(perform: toggle) }
    }
}
