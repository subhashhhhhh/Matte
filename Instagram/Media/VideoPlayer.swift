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
        #if DEBUG
        if !muted { FileHandle.standardError.write(Data("VIDEO new player\n".utf8)) }
        #endif
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

    func play() {
        player.play(); isPlaying = true
        #if DEBUG
        if !player.isMuted { FileHandle.standardError.write(Data("VIDEO play (sound)\n".utf8)) }
        #endif
    }
    func pause() {
        player.pause(); isPlaying = false
        #if DEBUG
        FileHandle.standardError.write(Data("VIDEO pause\n".utf8))
        #endif
    }
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
    /// Starts as set in Settings › Playback; the sound button changes it for this session.
    var muted = Preferences.shared.startMuted { didSet { PostMusic.shared.setMuted(muted) } }
}

/// Hands a playing video from one view to the next without stopping it: the full-size post and
/// the mini player (either way), or the Reels page and the mini player. While a handover is
/// expected (`expect()`), the arriving view claims the player the leaving view is still showing
/// (or one the Reels page offered), and the leaving view lets go of it without stopping it.
@MainActor
final class VideoHandoff {
    static let shared = VideoHandoff()
    /// Players on screen now, by post pk.
    private var live: [String: LoopingVideo] = [:]
    /// Players offered by a view that's already gone (the Reels page), let go of if unclaimed.
    private var offered: [String: (video: LoopingVideo, expiry: Task<Void, Never>)] = [:]
    /// Players claimed away from the view showing them: that view must not stop them.
    private var handedOff = Set<ObjectIdentifier>()
    private var expectingUntil = Date.distantPast

    /// A handover is about to happen (a post shrinking into the mini player, or growing back, or
    /// a feed preview opening as the full post: that one waits for the photo flight to land).
    func expect(for seconds: TimeInterval = 1.2) { expectingUntil = .now.addingTimeInterval(seconds) }
    var isExpecting: Bool { Date.now < expectingUntil }

    func register(_ video: LoopingVideo, key: String) { live[key] = video }

    /// The player was taken by another view, which now plays, pauses and mutes it.
    func isClaimed(_ video: LoopingVideo) -> Bool { handedOff.contains(ObjectIdentifier(video)) }

    /// The view showing `video` is leaving. True when the player was handed over (keep it going).
    func leave(_ video: LoopingVideo, key: String) -> Bool {
        if handedOff.remove(ObjectIdentifier(video)) != nil { return true }
        if live[key] === video { live[key] = nil }
        return false
    }

    /// Offers a player whose view is gone (the Reels page) to the next view of `key`.
    func offer(_ video: LoopingVideo, key: String) {
        guard isExpecting else { video.tearDown(); return }
        if let previous = offered[key] {
            previous.expiry.cancel()
            // Replaced before anyone took it: stop it (nothing else holds it, so it would play on).
            if previous.video !== video { previous.video.tearDown() }
        }
        let expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self, self.offered[key]?.video === video else { return }
            self.offered[key] = nil
            video.tearDown()
        }
        offered[key] = (video, expiry)
    }

    /// The playing player for `key` during a handover (it carries on where it was).
    func claim(_ key: String) -> LoopingVideo? {
        guard isExpecting else { return nil }
        if let entry = offered.removeValue(forKey: key) {
            entry.expiry.cancel()
            live[key] = entry.video
            return entry.video
        }
        guard let video = live[key] else { return nil }
        handedOff.insert(ObjectIdentifier(video))
        return video
    }
}
