import SwiftUI
import AVFoundation

/// Plays the stories tray: one account's items in order, then the next account.
/// Items are fetched a few reels ahead, as the web app does.
@Observable
final class StoryViewerModel {
    private(set) var reels: [StoryReel]
    private(set) var reelIndex: Int
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
    }

    var reel: StoryReel { reels[reelIndex] }
    var item: Media? { reel.items.indices.contains(itemIndex) ? reel.items[itemIndex] : nil }

    /// Loads the current reel (and the next two) if needed, then starts the item.
    private func prepare() async {
        await fetch(around: reelIndex)
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
        app?.feed?.markSeen(reel.id)
        Task { await fetch(around: reelIndex) }
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
            Task { await prepare() }
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
        Task { await prepare() }
    }

    func togglePause() {
        paused.toggle()
        if paused { video?.pause() } else { video?.play() }
    }

    // MARK: Replies

    /// Quick reactions, as instagram.com offers them under a story.
    static let quickReactions = ["😂", "😮", "😍", "😢", "👏", "🔥", "🎉", "💯"]
    private(set) var sending = false

    /// Whether you can reply to the current story (not your own).
    var canReply: Bool { item != nil && reel.user.id != app?.viewerId }

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
                    card(width: width, height: height)
                    sideButton("chevron.right", enabled: true) { model.next() }
                    ForEach(neighbors(before: false, count: fits), id: \.self) { i in
                        NeighborCard(reel: model.reels[i], size: small).onTapGesture { model.jump(toReel: i) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
