import SwiftUI
import AVFoundation
import AppKit

/// Reels, one at a time. Only the current reel and the next one hold a player; the rest
/// are just data, so memory stays flat however far you scroll.
@Observable
final class ReelsModel {
    private(set) var items: [Media] = []
    private(set) var index = 0
    private(set) var current: LoopingVideo?
    @ObservationIgnored private var upcoming: (pk: String, video: LoopingVideo)?
    private(set) var isLoading = false
    private(set) var loadFailed = false
    var isVisible = false {
        didSet { isVisible ? current?.play() : current?.pause() }
    }

    /// The current reel's caption and comments, for the side panel (loaded only if it's shown).
    private(set) var detail: MediaDetailModel?

    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var hasMore = true
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let client: IGClient

    init(app: AppModel, client: IGClient) {
        self.app = app
        self.client = client
    }

    var reel: Media? { items.indices.contains(index) ? items[index] : nil }

    func loadIfNeeded() async {
        guard items.isEmpty, !isLoading else { return }
        await loadMore()
        startCurrent()
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.reels(after: cursor)
            let known = Set(items.map(\.pk))
            items += page.items.filter { !known.contains($0.pk) && $0.isVideo }
            cursor = page.cursor
            hasMore = page.hasMore && page.cursor != nil
            loadFailed = false
        } catch {
            loadFailed = items.isEmpty
            app?.report(error)
        }
    }

    func move(_ delta: Int) {
        let target = index + delta
        guard items.indices.contains(target) else { return }
        index = target
        startCurrent()
        if items.count - index < 4 { Task { await loadMore() } }
    }

    func jump(to target: Int) { move(target - index) }

    private func startCurrent() {
        guard let reel else { return }
        if detail?.pk != reel.pk { detail = MediaDetailModel(pk: reel.pk, media: reel, client: client) }
        current?.tearDown()
        if let up = upcoming, up.pk == reel.pk {
            current = up.video
            upcoming = nil
        } else {
            upcoming?.video.tearDown()
            upcoming = nil
            current = reel.video(minWidth: 720).map { LoopingVideo(url: $0, muted: SoundSetting.shared.muted) }
        }
        current?.isMuted = SoundSetting.shared.muted
        if isVisible { current?.play() }
        // Buffer the next one so swiping to it starts at once.
        if items.indices.contains(index + 1), let url = items[index + 1].video(minWidth: 720) {
            upcoming = (items[index + 1].pk, LoopingVideo(url: url, muted: true))
        }
        MemoryRelief.soon()
    }

    func stop() {
        current?.tearDown()
        current = nil
        upcoming?.video.tearDown()
        upcoming = nil
        detail = nil
    }
}

struct ReelsView: View {
    let model: ReelsModel
    @Environment(AppModel.self) private var app
    @State private var sound = SoundSetting.shared
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height - 40
            let playerWidth = max(200, min(geo.size.width - 140, height * 9 / 16))
            // Use the room beside the 9:16 player: comments on the right, the queue on the left.
            let room = geo.size.width - playerWidth - 76 - 40
            let showsPanel = room >= 320
            let showsQueue = room >= 320 + 116 + 60
            let panelWidth = min(440, room - (showsQueue ? 116 : 0))
            HStack(alignment: .center, spacing: 20) {
                if showsQueue {
                    ReelQueue(model: model).frame(width: 96, height: height)
                }
                HStack(alignment: .bottom, spacing: 16) {
                    player(width: playerWidth, height: height, captionInPanel: showsPanel)
                    sideActions
                }
                if showsPanel, let detail = model.detail {
                    ReelPanel(model: detail)
                        .frame(width: panelWidth, height: height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ScrollWheelCatcher { model.move($0) })
        .overlay {
            if model.items.isEmpty {
                if model.loadFailed {
                    EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't load reels", actionTitle: "Try Again") {
                        Task { await model.loadIfNeeded() }
                    }
                } else {
                    Spinner(size: 22)
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { model.move(1); return .handled }
        .onKeyPress(.upArrow) { model.move(-1); return .handled }
        .onKeyPress(.space) { model.current?.toggle(); return .handled }
        .onKeyPress("m") { sound.muted.toggle(); return .handled }
        .onKeyPress(.rightArrow) { model.current?.seek(fraction: min(1, (model.current?.progress ?? 0) + 0.1)); return .handled }
        .onKeyPress(.leftArrow) { model.current?.seek(fraction: max(0, (model.current?.progress ?? 0) - 0.1)); return .handled }
        .onChange(of: sound.muted) { model.current?.isMuted = sound.muted }
        .task { await model.loadIfNeeded() }
        .onAppear { model.isVisible = true; focused = true }
        .onDisappear { model.isVisible = false }
    }

    @ViewBuilder
    private func player(width: CGFloat, height: CGFloat, captionInPanel: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let reel = model.reel {
                RemoteImage(url: reel.image(minWidth: 720), contentMode: .fit).id(reel.pk)
                if let v = model.current {
                    PlayerLayerView(player: v.player, gravity: .resizeAspect)
                        .onTapGesture { v.toggle() }
                    if !v.isPlaying {
                        Image(systemName: "play.fill").font(.system(size: 30)).foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                }
                info(reel, caption: !captionInPanel)
                if let v = model.current { ScrubBar(video: v) }
            }
        }
        .frame(width: max(width, 200), height: max(height, 300))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu { if let reel = model.reel { PostMenu(media: reel) } }
        .overlay(alignment: .topTrailing) { MuteButton().padding(12) }
    }

    private func info(_ reel: Media, caption showsCaption: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Avatar(url: reel.user?.avatar, size: 30)
                Text(reel.user?.username ?? "").font(.system(size: 13, weight: .semibold))
                if reel.user?.isVerified == true { VerifiedBadge(size: 11) }
            }
            if showsCaption, let caption = reel.caption, !caption.isEmpty {
                Text(caption).font(.system(size: 12.5)).lineLimit(2)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
    }

    private var sideActions: some View {
        VStack(spacing: 20) {
            if let reel = model.reel, let actions = app.actions {
                let state = actions.state(reel)
                VStack(spacing: 4) {
                    LikeButton(liked: state.liked, size: 26) { actions.toggleLike(reel) }
                    countLabel(reel.countsHidden ? nil : state.likeCount)
                }
                VStack(spacing: 4) {
                    IGGlyph(icon: .comment, size: 26)
                    countLabel(reel.commentCount)
                }
                .help("Comments")
                glyphButton(.share, help: "Send to…") { actions.send(reel) }
                glyphButton(state.saved ? .saveFilled : .save, help: state.saved ? "Remove from saved" : "Save") {
                    actions.toggleSave(reel)
                }
                Menu { PostMenu(media: reel) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold)).frame(width: 36, height: 30)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
            VStack(spacing: 6) {
                ChromeButton("Previous", symbol: "chevron.up") { model.move(-1) }.disabled(model.index == 0)
                ChromeButton("Next", symbol: "chevron.down") { model.move(1) }.disabled(model.index >= model.items.count - 1)
            }
            .padding(.top, 6)
        }
        .padding(.bottom, 20)
    }

    private func countLabel(_ count: Int?) -> some View {
        Text((count ?? 0) > 0 ? count!.compact : " ").font(.system(size: 11.5, weight: .semibold))
    }

    private func glyphButton(_ icon: IGIcon, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { IGGlyph(icon: icon, size: 26).contentShape(Rectangle()) }
            .buttonStyle(.pressable)
            .help(help)
    }
}

/// Thumbnails of the reels around the current one; click one to jump to it.
private struct ReelQueue: View {
    let model: ReelsModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(model.items.enumerated()), id: \.element.pk) { i, reel in
                        let current = i == model.index
                        RemoteImage(url: reel.image(minWidth: 200), contentMode: .fill)
                            .frame(width: 84, height: 84 * 16 / 9)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(current ? Color.primary : .clear, lineWidth: 2)
                            }
                            .opacity(i < model.index ? 0.45 : 1)
                            .contentShape(Rectangle())
                            .onTapGesture { model.jump(to: i) }
                            .id(reel.pk)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.08),
                                         .init(color: .black, location: 0.92), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: model.index, initial: true) {
                guard let pk = model.reel?.pk else { return }
                withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(pk, anchor: .center) }
            }
        }
    }
}

/// The current reel's author, full caption and comments, beside the player.
private struct ReelPanel: View {
    let model: MediaDetailModel

    var body: some View {
        MediaDetailsColumn(model: model)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panel))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.panelStroke))
            .task(id: model.pk) {
                // Skimming through reels shouldn't fetch comments for each one.
                try? await Task.sleep(for: .milliseconds(700))
                if !Task.isCancelled { await model.start() }
            }
    }
}

/// Turns trackpad/mouse-wheel scrolling into one-step moves (one reel per gesture).
struct ScrollWheelCatcher: NSViewRepresentable {
    var onStep: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onStep = onStep
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.onStep = onStep }

    static func dismantleNSView(_ v: CatcherView, coordinator: ()) { v.stop() }

    final class CatcherView: NSView {
        var onStep: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var lockedUntil = Date.distantPast

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                let p = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return event }
                self.handle(event)
                return nil
            }
        }

        private func handle(_ e: NSEvent) {
            if e.phase == .began { accumulated = 0 }
            guard Date.now > lockedUntil else { return }
            accumulated += e.scrollingDeltaY
            let threshold: CGFloat = e.hasPreciseScrollingDeltas ? 40 : 1
            if abs(accumulated) >= threshold {
                onStep?(accumulated < 0 ? 1 : -1)
                accumulated = 0
                // One reel per flick: ignore the momentum tail.
                lockedUntil = .now.addingTimeInterval(0.45)
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
