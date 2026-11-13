import SwiftUI
import AVFoundation

/// Draws an AVPlayer with a plain layer: no system controls. Clicks (and right-clicks) land on
/// a SwiftUI area above the layer, so taps and context menus attached around it work: a bare
/// AppKit view would swallow right-clicks and the post menu would never open over a video.
struct PlayerLayerView: View {
    let player: AVPlayer?
    var gravity: AVLayerVideoGravity = .resizeAspect

    var body: some View {
        PlayerLayer(player: player, gravity: gravity)
            .allowsHitTesting(false)
            .overlay { Color.clear.contentShape(Rectangle()) }
    }
}

private struct PlayerLayer: NSViewRepresentable {
    let player: AVPlayer?
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> PlayerNSView {
        let v = PlayerNSView()
        v.playerLayer.videoGravity = gravity
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ v: PlayerNSView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = gravity
    }

    static func dismantleNSView(_ v: PlayerNSView, coordinator: ()) {
        v.playerLayer.player = nil
    }

    final class PlayerNSView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = playerLayer
            playerLayer.backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError() }
        /// Never the target of a click: SwiftUI handles them (taps, the context menu).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// One looping video. Buffers only a few seconds ahead: a reel is short and the next one
/// is waiting, so a large buffer is memory spent on video nobody watches.
@Observable
final class LoopingVideo {
    let player: AVQueuePlayer
    @ObservationIgnored private var looper: AVPlayerLooper?
    @ObservationIgnored private var timeObserver: Any?
    private(set) var progress: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var isReady = false
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    /// Called once when the item finishes its first play-through (stories advance on it).
    @ObservationIgnored var onFinish: (() -> Void)?
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    init(url: URL, muted: Bool = false, loops: Bool = true) {
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 6
        player = AVQueuePlayer()
        player.isMuted = muted
        player.automaticallyWaitsToMinimizeStalling = true
        if loops {
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFinish?() }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let item = self.player.currentItem else { return }
                let d = item.duration.seconds
                if d.isFinite, d > 0 { self.duration = d; self.progress = min(1, t.seconds / d) }
                if !self.isReady, item.status == .readyToPlay { self.isReady = true }
            }
        }
    }

    func play() { player.play(); isPlaying = true }
    func pause() { player.pause(); isPlaying = false }
    func toggle() { isPlaying ? pause() : play() }
    func restart() { player.seek(to: .zero); play() }
    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    func seek(fraction: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: duration * fraction, preferredTimescale: 600))
    }

    /// Stops and lets go of the media buffers.
    func tearDown() {
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}

/// The app's sound setting, shared by every video (reels, stories, posts), as Instagram does.
@Observable
final class SoundSetting {
    static let shared = SoundSetting()
    var muted = false { didSet { PostMusic.shared.setMuted(muted) } }
}
