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

    private func startCurrent() {
        guard let reel else { return }
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
    }
}

struct ReelsView: View {
    let model: ReelsModel
    @State private var sound = SoundSetting.shared
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height - 32
            let width = min(geo.size.width - 140, height * 9 / 16)
            HStack(alignment: .bottom, spacing: 16) {
                player(width: width, height: height)
                sideActions
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
        .onChange(of: sound.muted) { model.current?.isMuted = sound.muted }
        .task { await model.loadIfNeeded() }
        .onAppear { model.isVisible = true; focused = true }
        .onDisappear { model.isVisible = false }
    }

    @ViewBuilder
    private func player(width: CGFloat, height: CGFloat) -> some View {
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
                info(reel)
                if let v = model.current { ProgressLine(video: v) }
            }
        }
        .frame(width: max(width, 200), height: max(height, 300))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) { MuteButton().padding(12) }
    }

    private func info(_ reel: Media) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Avatar(url: reel.user?.avatar, size: 30)
                Text(reel.user?.username ?? "").font(.system(size: 13, weight: .semibold))
                if reel.user?.isVerified == true { VerifiedBadge(size: 11) }
            }
            if let caption = reel.caption, !caption.isEmpty {
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
        VStack(spacing: 18) {
            if let reel = model.reel {
                stat(reel.hasLiked ? "heart.fill" : "heart", reel.likeCount, tint: reel.hasLiked ? Theme.like : nil)
                stat("bubble.right", reel.commentCount)
                if let url = reel.webURL {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right").font(.system(size: 16)) }
                        .buttonStyle(ChromeButtonStyle(size: 36))
                        .help("Open on Instagram")
                }
            }
            VStack(spacing: 6) {
                ChromeButton("Previous", symbol: "chevron.up") { model.move(-1) }.disabled(model.index == 0)
                ChromeButton("Next", symbol: "chevron.down") { model.move(1) }.disabled(model.index >= model.items.count - 1)
            }
            .padding(.top, 10)
        }
        .padding(.bottom, 20)
    }

    private func stat(_ symbol: String, _ count: Int?, tint: Color? = nil) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(tint ?? .primary)
            Text((count ?? 0) > 0 ? count!.compact : " ").font(.system(size: 11, weight: .medium))
        }
    }
}

private struct ProgressLine: View {
    let video: LoopingVideo
    var body: some View {
        GeometryReader { g in
            Rectangle().fill(.white.opacity(0.85)).frame(width: g.size.width * video.progress, height: 2)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
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
