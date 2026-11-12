import SwiftUI
import AVFoundation

/// Plays the stories tray: one account's items in order, then the next account.
/// Items are fetched a few reels ahead, as the web app does.
@Observable
final class StoryViewerModel {
    private(set) var reels: [StoryReel]
    private(set) var reelIndex: Int {
        didSet { forward = reelIndex >= oldValue }
    }
    /// Which way the last move between accounts went (the cube turns that way).
    private(set) var forward = true
    private(set) var itemIndex = 0
    /// 0…1 through the current item.
    private(set) var progress: Double = 0
    var paused = false
    private(set) var video: LoopingVideo?
    private(set) var loading = false

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let client: IGClient
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var requested = Set<String>()
    static let imageSeconds = 5.0

    init(app: AppModel, client: IGClient, reels: [StoryReel], start: Int) {
        self.app = app
        self.client = client
        self.reels = reels
        self.reelIndex = start
        Task { await self.prepare() }
        #if DEBUG
        debugLikeSoon()
        #endif
    }

    var reel: StoryReel { reels[reelIndex] }
    var item: Media? { reel.items.indices.contains(itemIndex) ? reel.items[itemIndex] : nil }

    /// Loads the current reel (and the next two) if needed, then starts the item.
    private func prepare(fromUnseen: Bool = true) async {
        await fetch(around: reelIndex)
        // Like Instagram: open an account at the first story you haven't seen.
        if fromUnseen, itemIndex == 0, let marker = reel.seenUpTo,
           let first = reel.items.firstIndex(where: { ($0.takenAt ?? .distantFuture) > marker }) {
            itemIndex = first
        }
        startItem()
    }

    private func fetch(around index: Int) async {
        let wanted = reels[index...].prefix(3).filter { $0.items.isEmpty && !requested.contains($0.id) }.map(\.id)
        guard !wanted.isEmpty else { return }
        requested.formUnion(wanted)
        if reels[index].items.isEmpty { loading = true }
        defer { loading = false }
        do {
            let loaded = try await client.storyReels(ids: wanted)
            for r in loaded {
                if let i = reels.firstIndex(where: { $0.id == r.id }) { reels[i].items = r.items }
            }
        } catch {
            requested.subtract(wanted)
            app?.report(error)
        }
    }

    private func startItem() {
        ticker?.cancel()
        video?.tearDown()
        video = nil
        progress = 0
        guard let item else {
            // An account whose stories expired meanwhile: skip it.
            if !loading, reel.items.isEmpty, requested.contains(reel.id) { nextReel() }
            return
        }
        if item.isVideo, let url = item.video(minWidth: 720) {
            let v = LoopingVideo(url: url, muted: SoundSetting.shared.muted, loops: false)
            v.onFinish = { [weak self] in self?.next() }
            video = v
            if !paused { v.play() }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled else { return }
                if let v = self.video {
                    self.progress = v.progress
                } else if !self.paused {
                    self.progress += 0.05 / Self.imageSeconds
                    if self.progress >= 1 { self.next(); return }
                }
            }
        }
        // Advance the seen marker to this story (the ring greys once the newest is watched).
        if let at = item.takenAt, (reels[reelIndex].seenUpTo ?? .distantPast) < at { reels[reelIndex].seenUpTo = at }
        app?.feed?.advanceSeen(reel.id, upTo: item.takenAt)
        markSeenSoon(item, reelId: reel.id)
        preloadAhead()
        Task { await fetch(around: reelIndex) }
    }

    @ObservationIgnored private var markedSeen = Set<String>()
    @ObservationIgnored private var seenTask: Task<Void, Never>?

    /// Logs the item as watched on Instagram once it has been on screen for a second (skipping
    /// past doesn't count), once per item.
    private func markSeenSoon(_ item: Media, reelId: String) {
        seenTask?.cancel()
        guard !markedSeen.contains(item.pk), reel.user.id != app?.viewerId else { return }
        #if DEBUG
        // Test launches never mark the user's stories as watched (only with `-IGMarkSeen YES`).
        guard UserDefaults.standard.bool(forKey: "IGMarkSeen") else { return }
        #endif
        seenTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, self.item?.pk == item.pk else { return }
            self.markedSeen.insert(item.pk)
            do { try await self.client.markStorySeen(reelId: reelId, media: item) } catch {
                self.markedSeen.remove(item.pk)
            }
        }
    }

    /// Downloads the next few items (this account's and the next one's first) so they show at once.
    private func preloadAhead() {
        var urls: [URL] = []
        let items = reel.items
        for i in (itemIndex + 1)..<min(items.count, itemIndex + 3) {
            if let u = items[i].image(minWidth: 720) { urls.append(u) }
        }
        if reels.indices.contains(reelIndex + 1), let first = reels[reelIndex + 1].items.first, let u = first.image(minWidth: 720) {
            urls.append(u)
        }
        Task { await ImagePipeline.shared.prefetch(urls) }
    }

    func next() {
        if itemIndex + 1 < reel.items.count {
            itemIndex += 1
            startItem()
        } else {
            nextReel()
        }
    }

    func previous() {
        if itemIndex > 0 {
            itemIndex -= 1
            startItem()
        } else if reelIndex > 0 {
            reelIndex -= 1
            itemIndex = 0
            Task { await prepare(fromUnseen: false) }
        } else {
            startItem()
        }
    }

    func nextReel() {
        guard reelIndex + 1 < reels.count else { close(); return }
        reelIndex += 1
        itemIndex = 0
        Task { await prepare() }
    }

    func jump(toReel i: Int) {
        guard reels.indices.contains(i), i != reelIndex else { return }
        reelIndex = i
        itemIndex = 0
        Task { await prepare() }
    }

    func previousReel() {
        guard reelIndex > 0 else { return }
        reelIndex -= 1
        itemIndex = 0
        Task { await prepare(fromUnseen: false) }
    }

    func togglePause() {
        paused.toggle()
        if paused { video?.pause() } else { video?.play() }
    }

    // MARK: Replies

    /// Quick reactions, as instagram.com offers them under a story.
    static let quickReactions = ["😂", "😮", "😍", "😢", "👏", "🔥", "🎉", "💯"]
    private(set) var sending = false

    /// Story items liked in this viewer (seeded from Instagram's `has_liked`).
    private(set) var liked = Set<String>()
    /// Observed (not ignored): the heart reads it, so a like must redraw the heart at once.
    private var likeOverrides = Set<String>()
    /// Bumped on each like: the big heart bursts over the story.
    private(set) var likeBurst = 0

    var isLiked: Bool {
        guard let item else { return false }
        return likeOverrides.contains(item.pk) ? liked.contains(item.pk) : item.hasLiked
    }

    /// Likes or unlikes the current story at once; undone if Instagram refuses.
    #if DEBUG
    /// `-IGStoryLikeTest YES` with `-IGDryRunWrites <dir>`: likes the open story after 3 s (nothing is
    /// sent: the dry run records it and fails), to watch the animation.
    func debugLikeSoon() {
        guard UserDefaults.standard.bool(forKey: "IGStoryLikeTest"),
              UserDefaults.standard.string(forKey: "IGDryRunWrites") != nil else { return }
        Task {
            while item == nil || !canReply { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .seconds(1.5))
            FileHandle.standardError.write(Data("STORYLIKE \(Date.now.timeIntervalSince1970)\n".utf8))
            toggleLike()
        }
    }
    #endif

    func toggleLike() {
        guard let item, canReply else { return }
        let now = !isLiked
        likeOverrides.insert(item.pk)
        if now { likeBurst += 1 }
        if now { liked.insert(item.pk) } else { liked.remove(item.pk) }
        Task {
            do { try await client.setStoryLiked(now, media: item) } catch {
                if now { liked.remove(item.pk) } else { liked.insert(item.pk) }
                app?.report(error)
            }
        }
    }

    /// Opens "Send to…" for the current story (sent as a story share).
    func share() {
        guard var item else { return }
        if item.user == nil { item.user = reel.user }
        if item.expiresAt == nil { item.expiresAt = .now.addingTimeInterval(86_400) }
        if !paused { togglePause() }
        app?.sharing = item
    }

    /// Whether you can reply to the current story (not your own).
    var canReply: Bool { item != nil && reel.user.id != app?.viewerId }
    /// Your own story: show who saw it instead of a reply box.
    var isOwn: Bool { item != nil && reel.user.id == app?.viewerId }

    // MARK: Deleting (your own stories)

    /// Your current story, still live (not a highlight or an archived one): it can be deleted.
    var canDelete: Bool {
        guard isOwn, let item, reel.id == reel.user.id else { return false }
        return (item.expiresAt ?? .distantPast) > .now
    }

    /// "Delete story?" is showing (the story waits meanwhile).
    var confirmingDelete = false {
        didSet {
            guard confirmingDelete != oldValue else { return }
            if confirmingDelete {
                if !paused { togglePause(); pausedForDelete = true }
            } else if pausedForDelete {
                if paused { togglePause() }
                pausedForDelete = false
            }
        }
    }
    @ObservationIgnored private var pausedForDelete = false
    private(set) var deleting = false

    /// Deletes the current story after the confirmation, then plays on (or closes if it was
    /// the last one).
    func deleteCurrent() async {
        guard canDelete, let item, !deleting else { return }
        deleting = true
        defer { deleting = false }
        do {
            try await client.deleteStory(pk: item.pk)
            pausedForDelete = false
            confirmingDelete = false
            app?.show("Story deleted")
            Task { await app?.feed?.refreshTray() }
            reels[reelIndex].items.removeAll { $0.pk == item.pk }
            if reels[reelIndex].items.isEmpty {
                close()
                return
            }
            itemIndex = min(itemIndex, reels[reelIndex].items.count - 1)
            if paused { togglePause() }
            startItem()
        } catch {
            app?.report(error)
        }
    }

    // MARK: Viewers (your own stories)

    private(set) var viewers: [StoryViewerEntry] = []
    private(set) var viewersTotal: Int?
    private(set) var loadingViewers = false
    var showingViewers = false {
        didSet {
            guard showingViewers != oldValue else { return }
            if showingViewers {
                if !paused { togglePause(); pausedForViewers = true }
                Task { await loadViewers() }
            } else if pausedForViewers {
                if paused { togglePause() }
                pausedForViewers = false
            }
        }
    }
    @ObservationIgnored private var pausedForViewers = false
    @ObservationIgnored private var viewersFor: String?
    @ObservationIgnored private var viewersCursor: String?

    func loadViewers(more: Bool = false) async {
        guard let item, isOwn, !loadingViewers else { return }
        if viewersFor != item.pk { viewers = []; viewersTotal = nil; viewersCursor = nil; viewersFor = item.pk }
        if more, viewersCursor == nil { return }
        loadingViewers = true
        defer { loadingViewers = false }
        do {
            let page = try await client.storyViewers(mediaPk: item.pk, cursor: more ? viewersCursor : nil)
            guard viewersFor == item.pk else { return }
            let known = Set(viewers.map(\.id))
            viewers += page.viewers.filter { !known.contains($0.id) }
            viewersTotal = page.total
            viewersCursor = page.next
        } catch {
            app?.report(error)
        }
    }

    /// Replies to the current story (a DM to its owner): with text, or a quick reaction.
    func reply(text: String? = nil, emoji: String? = nil) async -> Bool {
        guard let item, canReply, !sending else { return false }
        let text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (text?.isEmpty == false) || emoji != nil else { return false }
        sending = true
        defer { sending = false }
        do {
            try await client.replyToStory(mediaId: item.pk, reelId: reel.id, ownerId: reel.user.id,
                                          text: emoji == nil ? text : nil, emoji: emoji)
            app?.show(emoji == nil ? "Sent" : "Sent \(emoji!)")
            return true
        } catch {
            app?.report(error)
            return false
        }
    }

    func close() {
        ticker?.cancel()
        video?.tearDown()
        video = nil
        app?.stories = nil
        MemoryRelief.soon()
    }
}

/// "Reply to …" under a story, with quick reactions above it while you're replying. The story
/// pauses while the box has focus.
private struct StoryReplyBar: View {
    let model: StoryViewerModel
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var pausedByUs = false

    var body: some View {
        VStack(spacing: 10) {
            if focused {
                HStack(spacing: 2) {
                    ForEach(StoryViewerModel.quickReactions, id: \.self) { e in
                        Button { send(emoji: e) } label: {
                            Text(e).font(.system(size: 24)).frame(width: 38, height: 38)
                        }
                        .buttonStyle(.pressable)
                        .help("React with \(e)")
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Capsule().fill(.black.opacity(0.55)))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(spacing: 10) {
                TextField("Reply to \(model.reel.user.username)…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .focused($focused)
                    .onSubmit { send() }
                    .disabled(model.sending)
                if model.sending {
                    Spinner(size: 14)
                } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Send") { send() }
                        .buttonStyle(.plain)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Button { focused = true } label: {
                        Image(systemName: "face.smiling").font(.system(size: 19)).foregroundStyle(.white).frame(width: 30, height: 30)
                    }
                    .buttonStyle(.pressable)
                    .help("Quick reactions")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 42)
            .overlay(Capsule().strokeBorder(.white.opacity(0.6), lineWidth: 1))
            .overlay(alignment: .trailing) {
                // Like the story (Instagram's heart beside the reply box).
                Button { model.toggleLike() } label: {
                    IGGlyph(icon: model.isLiked ? .heartFilled : .heart, size: 24)
                        .foregroundStyle(model.isLiked ? AnyShapeStyle(Theme.like) : AnyShapeStyle(.white))
                        .keyframeAnimator(initialValue: 1.0, trigger: model.likeBurst) { view, scale in
                            view.scaleEffect(scale)
                        } keyframes: { _ in
                            // Instagram's heart: a quick swell, a slight overshoot back, settle.
                            SpringKeyframe(1.45, duration: 0.14, spring: .snappy)
                            SpringKeyframe(0.9, duration: 0.12, spring: .snappy)
                            SpringKeyframe(1.0, duration: 0.2, spring: .bouncy)
                        }
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .help(model.isLiked ? "Unlike" : "Like")
                .offset(x: 46)
            }
            .overlay(alignment: .trailing) {
                // Send the story to a chat (Instagram's paper plane beside the heart).
                Button { model.share() } label: {
                    IGGlyph(icon: .share, size: 22)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .help("Send to…")
                .offset(x: 88)
            }
            .padding(.trailing, 88)
        }
        .animation(.smooth(duration: 0.2), value: focused)
        .onChange(of: focused) { _, isFocused in
            // Hold the story still while typing; carry on when you leave the box.
            if isFocused, !model.paused { model.togglePause(); pausedByUs = true }
            if !isFocused, pausedByUs { if model.paused { model.togglePause() }; pausedByUs = false }
        }
        .onChange(of: model.item?.pk) { text = "" }
    }

    private func send(emoji: String? = nil) {
        let reply = text
        Task {
            if await model.reply(text: reply, emoji: emoji) {
                if emoji == nil { text = "" }
                focused = false
            }
        }
    }
}

struct StoryViewer: View {
    let model: StoryViewerModel
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
                .onTapGesture { model.close() }
            GeometryReader { geo in
                let height = geo.size.height - 48
                let width = min(geo.size.width - 120, height * 9 / 16)
                let small = CGSize(width: width * 0.42, height: width * 0.42 * 16 / 9)
                // Room beside the card: the accounts before and after it, smaller, as on the web.
                let fits = max(0, min(2, Int((geo.size.width - width - 120) / 2 / (small.width + 16))))
                HStack(spacing: 16) {
                    ForEach(neighbors(before: true, count: fits), id: \.self) { i in
                        NeighborCard(reel: model.reels[i], size: small).onTapGesture { model.jump(toReel: i) }
                    }
                    sideButton("chevron.left", enabled: model.reelIndex > 0 || model.itemIndex > 0) { model.previous() }
                    ZStack {
                        card(width: width, height: height)
                            .id(model.reelIndex)
                            .transition(.cube(forward: model.forward))
                    }
                    .frame(width: width, height: height)
                    sideButton("chevron.right", enabled: true) { model.next() }
                    ForEach(neighbors(before: false, count: fits), id: \.self) { i in
                        NeighborCard(reel: model.reels[i], size: small).onTapGesture { model.jump(toReel: i) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(Motion.page, value: model.reelIndex)
                .popIn(from: 0.9)
            }
            VStack {
                HStack {
                    Spacer()
                    Button { model.close() } label: {
                        Image(systemName: "xmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.pressable)
                    .keyboardShortcut(.cancelAction)
                }
                Spacer()
            }
            .padding(16)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { model.previous(); return .handled }
        .onKeyPress(.rightArrow) { model.next(); return .handled }
        .onKeyPress(.space) { model.togglePause(); return .handled }
        .onKeyPress(.downArrow) { model.nextReel(); return .handled }
        .onKeyPress(.upArrow) { model.previousReel(); return .handled }
    }

    /// Reel indices shown beside the card: `count` before it (nearest last) or after it.
    private func neighbors(before: Bool, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let r = model.reelIndex
        return before ? Array(max(0, r - count)..<r) : Array((r + 1)..<min(model.reels.count, r + 1 + count))
    }

    private func card(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color(white: 0.08)
            if let item = model.item {
                RemoteImage(url: item.image(minWidth: 720), contentMode: .fit)
                    .id(item.pk)
                if let video = model.video {
                    PlayerLayerView(player: video.player, gravity: .resizeAspect)
                }
            } else {
                Spinner(size: 22)
            }
            // Tap halves: back and forward, as on the phone.
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { model.previous() }
                Color.clear.contentShape(Rectangle()).onTapGesture { model.next() }
            }
            VStack(spacing: 10) {
                progressBars
                header
                Spacer()
                if model.canReply { StoryReplyBar(model: model) }
                if model.isOwn { SeenByButton(model: model) }
            }
            .padding(12)
            .background(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom).frame(height: 110)
            }
            .background(alignment: .bottom) {
                if model.canReply {
                    LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom).frame(height: 120)
                        .allowsHitTesting(false)
                }
            }
        }
        .overlay { HeartBurst(trigger: model.likeBurst) }
        .overlay(alignment: .bottom) {
            if model.showingViewers {
                StoryViewersSheet(model: model)
                    .frame(height: height * 0.62)
                    .transition(.move(edge: .bottom))
            }
        }
        .animation(Motion.pop, value: model.showingViewers)
        .overlay {
            if model.confirmingDelete {
                StoryDeleteConfirm(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: model.confirmingDelete)
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var progressBars: some View {
        HStack(spacing: 3) {
            ForEach(Array(model.reel.items.enumerated()), id: \.element.pk) { i, _ in
                GeometryReader { g in
                    Capsule().fill(.white.opacity(0.35))
                        .overlay(alignment: .leading) {
                            Capsule().fill(.white)
                                .frame(width: g.size.width * (i < model.itemIndex ? 1 : i == model.itemIndex ? model.progress : 0))
                        }
                }
                .frame(height: 2.5)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Avatar(url: model.reel.user.avatar, size: 30)
                Text(model.reel.user.username).font(.system(size: 13, weight: .semibold))
            }
            .opensProfile(model.reel.user)
            if let t = model.item?.takenAt {
                Text(t.shortAge).font(.system(size: 13)).opacity(0.75)
            }
            Spacer()
            if model.video != nil { MuteButton() }
            Button { model.togglePause() } label: {
                Image(systemName: model.paused ? "play.fill" : "pause.fill").font(.system(size: 13))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.pressable)
            if model.canDelete {
                Button { model.confirmingDelete = true } label: {
                    IGGlyph(icon: .more, size: 18).frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .help("More")
                .contextMenu { Button("Delete Story…") { model.confirmingDelete = true } }
            }
        }
        .foregroundStyle(.white)
    }

    private func sideButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(0.85)))
        }
        .buttonStyle(.pressable)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
    }
}

/// "Delete story?" over your story: Delete (red) or Cancel, in the app's dialog style.
private struct StoryDeleteConfirm: View {
    let model: StoryViewerModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).onTapGesture { if !model.deleting { model.confirmingDelete = false } }
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text("Delete story?").font(.system(size: 16, weight: .bold))
                    Text("It's removed for everyone and from your archive.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20).padding(.vertical, 22)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Button { Task { await model.deleteCurrent() } } label: {
                    HStack(spacing: 8) {
                        if model.deleting { Spinner(size: 13) }
                        Text(model.deleting ? "Deleting…" : "Delete")
                    }
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.like)
                    .frame(maxWidth: .infinity).frame(height: 46).contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .disabled(model.deleting)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                Button { model.confirmingDelete = false } label: {
                    Text("Cancel").font(.system(size: 14)).frame(maxWidth: .infinity).frame(height: 46).contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .disabled(model.deleting)
            }
            .frame(width: 280)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.background))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .environment(\.colorScheme, .dark)
            .popIn()
        }
    }
}

/// Another account's stories beside the open one: its first story if loaded, else its avatar.
private struct NeighborCard: View {
    let reel: StoryReel
    let size: CGSize
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color(white: 0.12)
            if let first = reel.items.first {
                RemoteImage(url: first.image(minWidth: size.width * 2), contentMode: .fill)
            }
            Color.black.opacity(hovering ? 0.25 : 0.45)
            VStack(spacing: 8) {
                StoryRing(seen: reel.seen) { Avatar(url: reel.user.avatar, size: 46) }
                Text(reel.user.username).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                if let t = reel.latest {
                    Text(t.shortAge).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(8)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}


/// "Seen by N" with the first viewers' faces, under your own story.
private struct SeenByButton: View {
    let model: StoryViewerModel

    var body: some View {
        let item = model.item
        Button { model.showingViewers = true } label: {
            HStack(spacing: 8) {
                HStack(spacing: -8) {
                    ForEach(Array((item?.storyViewers ?? []).prefix(3).enumerated()), id: \.element.id) { i, u in
                        Avatar(url: u.avatar, size: 24)
                            .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                            .zIndex(Double(3 - i))
                    }
                }
                Text(seenText(item?.storyViewerCount))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Capsule().fill(.black.opacity(0.45)))
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Viewers")
    }

    private func seenText(_ n: Int?) -> String {
        guard let n, n > 0 else { return "No viewers yet" }
        return "Seen by \(n)"
    }
}

/// Who viewed your story: likes marked with a red heart, replies shown under the name.
private struct StoryViewersSheet: View {
    let model: StoryViewerModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.viewersTotal.map { "\($0) \($0 == 1 ? "viewer" : "viewers")" } ?? "Viewers")
                    .font(.system(size: 14, weight: .bold))
                let likes = model.viewers.filter(\.liked).count
                if likes > 0 {
                    HStack(spacing: 3) {
                        IGGlyph(icon: .heartFilled, size: 12).foregroundStyle(Theme.like)
                        Text("\(likes)").font(.system(size: 12.5, weight: .semibold))
                    }
                    .padding(.leading, 6)
                }
                Spacer()
                Button { model.showingViewers = false } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28)
                }
                .buttonStyle(.pressable)
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.viewers) { v in
                        HStack(spacing: 10) {
                            Avatar(url: v.user.avatar, size: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(v.user.username).font(.system(size: 13.5, weight: .semibold))
                                if let reply = v.reply {
                                    Text("Replied: \(reply)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                } else if !v.user.fullName.isEmpty {
                                    Text(v.user.fullName).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if v.liked { IGGlyph(icon: .heartFilled, size: 16).foregroundStyle(Theme.like).help("Liked your story") }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .opensProfile(v.user)
                        .onAppear { if v.id == model.viewers.last?.id { Task { await model.loadViewers(more: true) } } }
                    }
                    if model.loadingViewers { Spinner(size: 14).padding(12) }
                    if !model.loadingViewers, model.viewers.isEmpty {
                        Text("No one has viewed this yet").font(.system(size: 13)).foregroundStyle(.secondary).padding(24)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
        }
        .background(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous).fill(Theme.background))
        .environment(\.colorScheme, .dark)
    }
}


/// A big heart that pops over the story and fades when you like it, so the like is unmistakable.
private struct HeartBurst: View {
    let trigger: Int
    @State private var shown = false

    var body: some View {
        IGGlyph(icon: .heartFilled, size: 110)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 18)
            .keyframeAnimator(initialValue: BurstFrame(), trigger: trigger) { view, f in
                view.scaleEffect(f.scale).opacity(f.opacity).rotationEffect(.degrees(f.tilt))
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    SpringKeyframe(1.15, duration: 0.22, spring: .bouncy)
                    SpringKeyframe(1.0, duration: 0.18)
                    CubicKeyframe(1.0, duration: 0.25)
                    CubicKeyframe(1.3, duration: 0.25)
                }
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(1, duration: 0.08)
                    LinearKeyframe(1, duration: 0.57)
                    CubicKeyframe(0, duration: 0.25)
                }
                KeyframeTrack(\.tilt) {
                    SpringKeyframe(-8, duration: 0.2)
                    SpringKeyframe(0, duration: 0.3)
                }
            }
            .allowsHitTesting(false)
    }

    struct BurstFrame {
        var scale: CGFloat = 0.2
        var opacity: Double = 0
        var tilt: Double = 0
    }
}
