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

    func close() {
        ticker?.cancel()
        video?.tearDown()
        video = nil
        app?.stories = nil
        MemoryRelief.soon()
    }
}

struct StoryViewer: View {
    let model: StoryViewerModel
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
                .onTapGesture { model.close() }
            HStack(spacing: 18) {
                sideButton("chevron.left", enabled: model.reelIndex > 0 || model.itemIndex > 0) { model.previous() }
                card
                sideButton("chevron.right", enabled: true) { model.next() }
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

    private var card: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let width = min(geo.size.width, height * 9 / 16)
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
                }
                .padding(12)
                .background(alignment: .top) {
                    LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom).frame(height: 110)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: 560)
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
            Avatar(url: model.reel.user.avatar, size: 30)
            Text(model.reel.user.username).font(.system(size: 13, weight: .semibold))
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
