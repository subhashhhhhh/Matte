import SwiftUI
import AVFoundation

/// Songs on photo posts. The feed doesn't say which posts have one: a post's own info does,
/// so it's asked once per post when you rest on it or open it, and remembered.
@Observable
final class PostMusic {
    static let shared = PostMusic()

    /// The post whose song is playing.
    private(set) var playingPk: String?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var endObserver: Any?
    @ObservationIgnored private var known: [String: MusicTrack?] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var asking: [String: Task<MusicTrack?, Never>] = [:]

    /// The post's song, asking Instagram once (nil: none).
    func track(for media: Media, client: IGClient?) async -> MusicTrack? {
        if let m = media.music { return m }
        guard !media.isVideo, media.expiresAt == nil else { return nil }
        if let hit = known[media.pk] { return hit }
        guard let client else { return nil }
        if let running = asking[media.pk] { return await running.value }
        let task = Task { (try? await client.mediaInfo(pk: media.pk))?.music }
        asking[media.pk] = task
        let found = await task.value
        asking[media.pk] = nil
        remember(media.pk, found)
        return found
    }

    /// Known without asking (nil when unknown or none).
    func cached(_ pk: String) -> MusicTrack? { known[pk] ?? nil }

    private func remember(_ pk: String, _ track: MusicTrack?) {
        known[pk] = .some(track)
        order.append(pk)
        // A few hundred posts' worth, then the oldest go.
        if order.count > 400 { known[order.removeFirst()] = nil }
    }

    /// Views using the playing song (a hovered card and the opened post can share it).
    @ObservationIgnored private var holders: Set<UUID> = []

    /// Plays the poster's part of the song, over and over, while any holder wants it.
    func play(_ track: MusicTrack, for pk: String, holder: UUID) {
        if playingPk == pk { pendingStop?.cancel(); holders.insert(holder); return }
        stop()
        holders = [holder]
        let item = AVPlayerItem(url: track.url)
        let start = CMTime(value: CMTimeValue(track.startMs), timescale: 1000)
        let end = CMTime(value: CMTimeValue(track.startMs + max(track.durationMs, 5000)), timescale: 1000)
        item.forwardPlaybackEndTime = end
        item.preferredForwardBufferDuration = 10
        let p = AVPlayer(playerItem: item)
        p.isMuted = SoundSetting.shared.muted
        p.seek(to: start, toleranceBefore: .zero, toleranceAfter: .positiveInfinity)
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak p] _ in
            p?.seek(to: start)
            p?.play()
        }
        p.play()
        player = p
        playingPk = pk
        #if DEBUG
        FileHandle.standardError.write(Data("MUSIC play \(pk)\n".utf8))
        #endif
    }

    @ObservationIgnored private var pendingStop: Task<Void, Never>?

    /// The holder is done with it; the song stops when nobody holds it. During a handover
    /// (the post shrinking into the mini player or growing back) it waits a moment for the
    /// next view to take it, so it never stops.
    func release(_ holder: UUID) {
        guard holders.remove(holder) != nil, holders.isEmpty else { return }
        guard VideoHandoff.shared.isExpecting else { stop(); return }
        pendingStop?.cancel()
        pendingStop = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self, self.holders.isEmpty else { return }
            self.stop()
        }
    }

    func stop() {
        #if DEBUG
        if playingPk != nil { FileHandle.standardError.write(Data("MUSIC stop\n".utf8)) }
        #endif
        holders = []
        player?.pause()
        player = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        playingPk = nil
    }

    func setMuted(_ muted: Bool) { player?.isMuted = muted }
}

/// "♪ Title · Artist", as Instagram shows a post's song under its author.
struct MusicLine: View {
    let title: String
    let artist: String
    var fontSize: CGFloat = 12
    var playing = false

    init(track: MusicTrack, fontSize: CGFloat = 12, playing: Bool = false) {
        self.init(title: track.title, artist: track.artist, fontSize: fontSize, playing: playing)
    }

    init(title: String, artist: String, fontSize: CGFloat = 12, playing: Bool = false) {
        self.title = title
        self.artist = artist
        self.fontSize = fontSize
        self.playing = playing
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: playing ? "waveform" : "music.note")
                .font(.system(size: fontSize - 1, weight: .semibold))
                .symbolEffect(.variableColor.iterative, isActive: playing)
            Text([title, artist].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.system(size: fontSize))
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
    }
}
