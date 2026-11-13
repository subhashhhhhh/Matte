import SwiftUI
import AVFoundation
import CoreImage
import OSLog
import Synchronization

/// The story editor: one photo or video on a 9:16 canvas with text, stickers, a drawing and a
/// filter, undo for all of it, and Share, which flattens the canvas (`StoryExport`) and hands
/// the file to the create flow's story upload (`CreateModel.shareFinishedStory`).
///
/// Only small things are held: the background decoded at screen size, one raster of the
/// drawing, a raster per text item. The full-size picture is decoded only while exporting.
@Observable
final class StoryEditorModel {
    enum Mode: Equatable {
        case normal
        case text(UUID)
        case draw
        case stickers
        case filters
        case background
    }

    enum Export: Equatable {
        case idle
        case rendering(Double)
        case failed(String)
    }

    private(set) var source: CreateSource?
    private(set) var doc = StoryDoc() {
        didSet {
            if doc.background != oldValue.background || doc.filter != oldValue.filter { refreshBackdrop() }
        }
    }
    /// The blurred background at screen size (when the background is "Blur").
    private(set) var backdropPreview: CGImage?
    /// A shared post's card look (clicking the card switches it).
    private(set) var cardStyle: PostStoryCard.Style = .full
    /// The background at screen size, as picked and with the filter on.
    private(set) var display: CGImage?
    private(set) var filtered: CGImage?
    private(set) var gradient: StoryExport.Gradient = (StoryColor(hex: 0x833AB4), StoryColor(hex: 0xF77737))
    private(set) var filterThumbs: [StoryFilter: CGImage] = [:]
    private(set) var video: StoryVideo?
    private(set) var drawingImage: CGImage?
    private(set) var loading = false
    private(set) var notice: String?

    var selection: UUID?
    private(set) var mode: Mode = .normal
    /// The text being typed (applied to its item when editing ends).
    var draft = StoryText()
    var brush: StoryStroke.Brush = .pen
    var brushColor: StoryColor = .white
    var brushWidth = 1
    var confirmingClose = false

    private(set) var export: Export = .idle
    /// The upload and publish, once the file is made (its progress, status and errors).
    private(set) var sharer: CreateModel?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let client: IGClient
    @ObservationIgnored private var undoStack: [StoryDoc] = []
    @ObservationIgnored private var redoStack: [StoryDoc] = []
    private(set) var canUndo = false
    private(set) var canRedo = false
    /// The document when the media was loaded ("Undo all" goes back to it).
    @ObservationIgnored private var original = StoryDoc()
    @ObservationIgnored private var textBefore: StoryDoc?
    @ObservationIgnored private var textIsNew = false
    @ObservationIgnored private var lastText = StoryText()
    @ObservationIgnored private var images: [UUID: (kind: StoryItem.Kind, ppu: CGFloat, piece: Piece)] = [:]
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var backdropTask: Task<Void, Never>?
    /// The picture, tiny: the gradient's colours and the blurred background come from it.
    @ObservationIgnored private var small: CGImage?
    @ObservationIgnored private var reshareMedia: Media?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var exported: (doc: StoryDoc, media: PreparedMedia)?
    @ObservationIgnored private var gestureBefore: StoryDoc?
    /// Screen pixels per canvas unit (the canvas view sets it as the window resizes).
    @ObservationIgnored private(set) var displayPPU: CGFloat = 1
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Matte", category: "StoryEditor")

    init(app: AppModel?, client: IGClient) {
        self.app = app
        self.client = client
    }

    /// Adding a post or reel to your story: the card is the picture, with a tappable sticker over it.
    private(set) var reshare: StoryReshare?

    var hasMedia: Bool { source != nil }
    var isVideo: Bool { source?.isVideo ?? false }
    var hasEdits: Bool { doc != original }
    var isBusy: Bool {
        if case .rendering = export { return true }
        return sharer?.isSharing ?? false
    }
    var editingText: UUID? {
        if case .text(let id) = mode { return id }
        return nil
    }
    var aspect: CGFloat { source?.aspect ?? 9.0 / 16 }
    var bgRect: CGRect { doc.bgRect(aspect: aspect) }
    var duration: Double { Double(source?.durationMs ?? 0) / 1000 }

    // MARK: Loading

    func load(_ url: URL) async {
        notice = nil
        loading = true
        defer { loading = false }
        do {
            let s = try await CreateMedia.read(url)
            let small = await CreateMedia.still(s, maxPixels: 240)
            // Screen size: a canvas fills at most a window's height on a Retina screen, with
            // room to zoom in a little before it softens.
            let shown = s.isVideo ? nil : await CreateMedia.still(s, maxPixels: 2048)
            tearDownVideo()
            source = s
            display = shown
            filtered = nil
            images = [:]
            var fresh = StoryDoc()
            fresh.items = doc.items
            fresh.strokes = doc.strokes
            if s.isVideo {
                fresh.trimEnd = min(Double(s.durationMs ?? 0) / 1000, CreateMedia.maxStorySeconds)
                video = StoryVideo(url: s.url, end: fresh.trimEnd)
            }
            doc = fresh
            original = StoryDoc(trimStart: fresh.trimStart, trimEnd: fresh.trimEnd)
            undoStack = []
            redoStack = []
            syncUndo()
            exported = nil
            self.small = small
            refreshBackdrop()
            if let small {
                gradient = StoryRenderer.gradient(from: small)
                filterThumbs = await Self.thumbs(small)
            }
            MemoryRelief.soon()
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Starts a story from a post or reel, as the phone app does: its card (author, picture,
    /// caption), a little narrower than the story, on the picture blurred.
    func loadReshare(_ media: Media) async {
        loading = true
        reshareMedia = media
        if media.productType == "clips" || (media.isVideo && media.children.isEmpty) {
            await loadReelReshare(media)
            return
        }
        cardStyle = .full
        guard let file = await PostStoryCard.render(media, style: .full) else {
            loading = false
            notice = "Couldn't load this post."
            return
        }
        await load(file)
        guard source != nil else { return }
        doc.bgScale = PostStoryCard.width / StoryDoc.size.width
        // The colours from the photo, not the card's white edges.
        if let small, let middle = small.cropping(to: CGRect(x: small.width / 5, y: small.height / 4,
                                                            width: small.width * 3 / 5, height: small.height / 2)) {
            gradient = StoryRenderer.gradient(from: middle)
        }
        doc.background = .blur
        // The post's song comes along, as on the phone (Sound turns it off).
        doc.music = await PostMusic.shared.track(for: media, client: client)
        original = doc
        reshare = StoryReshare(mediaPk: media.pk, ownerId: media.user?.id ?? "")
        playMusic()
    }

    @ObservationIgnored private let musicHolder = UUID()

    /// Plays the story's song while editing (not when its sound is off).
    private func playMusic() {
        guard let music = doc.music, let reshare = reshareMedia else { return }
        if doc.muted { PostMusic.shared.release(musicHolder) } else { PostMusic.shared.play(music, for: "story-" + reshare.pk, holder: musicHolder) }
    }

    /// The story has sound to switch: a video's, or a shared post's song.
    var hasSound: Bool { isVideo || doc.music != nil }

    /// A shared reel, as the phone app does it: its video fills the story with the author's
    /// name at the top; clicking it makes it a rounded card with the name and length inside.
    private func loadReelReshare(_ media: Media) async {
        var full = media
        if full.video(minWidth: 720) == nil, let fetched = try? await client.mediaInfo(pk: media.pk) { full = fetched }
        guard let url = full.video(minWidth: 720) else {
            loading = false
            notice = "Couldn't load this reel."
            return
        }
        do {
            let (temp, _) = try await URLSession.shared.download(from: url)
            let file = CreateMedia.folder.appending(path: "reshare-\(UUID().uuidString).mp4")
            try FileManager.default.moveItem(at: temp, to: file)
            await load(file)
        } catch {
            loading = false
            notice = "Couldn't load this reel."
            return
        }
        guard let source else { return }
        let seconds = Double(source.durationMs ?? 0) / 1000
        reelLabels = (media.user?.username ?? "", String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60))
        cardStyle = .photo
        applyReelLook(.full, to: &doc)
        // The phone app's dark backdrop behind a reel card.
        doc.background = .color(StoryColor(hex: 0x161616))
        original = doc
        reshare = StoryReshare(mediaPk: media.pk, ownerId: media.user?.id ?? "")
    }

    /// The reel's author and length, for its labels.
    @ObservationIgnored private var reelLabels: (name: String, length: String)?
    var isReelReshare: Bool { reelLabels != nil }

    /// Full screen (`.full`: fills the story, name at the top) or card (`.photo`: rounded, a
    /// little smaller, name and length inside).
    private func applyReelLook(_ look: PostStoryCard.Style, to d: inout StoryDoc) {
        guard let source, let labels = reelLabels else { return }
        let a = source.aspect
        d.bgOffset = .zero
        switch look {
        case .full:
            // Cover the story (a 9:16 reel exactly fills it).
            let fit = StoryDoc().bgRect(aspect: a)
            d.bgScale = max(StoryDoc.size.width / fit.width, StoryDoc.size.height / fit.height)
            d.frame = StoryPictureFrame(radius: 0, leading: labels.name, trailing: nil, inside: false, aspect: a)
        case .photo:
            d.bgScale = 0.8
            d.frame = StoryPictureFrame(radius: 44, leading: labels.name, trailing: labels.length, inside: true, aspect: a)
        }
        cardStyle = look
    }

    /// Switches a shared post between the full card and the picture alone (clicking the card),
    /// or a shared reel between full screen and its card. Keeps where it is, its size and
    /// everything else on the story.
    func toggleCardStyle() {
        if isReelReshare {
            // From the document, so it stays right after undo.
            let next: PostStoryCard.Style = doc.frame?.inside == true ? .full : .photo
            commit { applyReelLook(next, to: &$0) }
            return
        }
        guard let media = reshareMedia, !isBusy, !loading else { return }
        let next: PostStoryCard.Style = cardStyle == .full ? .photo : .full
        loading = true
        Task {
            defer { loading = false }
            guard let file = await PostStoryCard.render(media, style: next),
                  let s = try? await CreateMedia.read(file) else { return }
            let shown = await CreateMedia.still(s, maxPixels: 2048)
            source = s
            display = shown
            filtered = nil
            exported = nil
            cardStyle = next
            applyFilter()
            MemoryRelief.soon()
        }
    }

    func setBackground(_ b: StoryBackground) {
        commit { $0.background = b }
    }

    /// Draws the blurred background for the canvas from the tiny picture, with the same recipe
    /// as the export (so what you see is what's shared).
    private func refreshBackdrop() {
        backdropTask?.cancel()
        guard doc.background == .blur, let small else { backdropPreview = nil; return }
        let doc = doc, gradient = gradient
        backdropTask = Task {
            let image = await Self.backdrop(small, doc: doc, gradient: gradient)
            if !Task.isCancelled { backdropPreview = image }
        }
    }

    @concurrent
    private static func backdrop(_ image: CGImage, doc: StoryDoc, gradient: StoryExport.Gradient) async -> CGImage? {
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let full = StoryRenderer.backdrop(source: CIImage(cgImage: image), doc: doc, gradient: gradient)
        let k: CGFloat = 0.25
        let out = full.transformed(by: CGAffineTransform(scaleX: k, y: k))
        return ctx.createCGImage(out, from: CGRect(x: 0, y: 0, width: StoryDoc.size.width * k, height: StoryDoc.size.height * k))
    }

    @concurrent
    private static func thumbs(_ image: CGImage) async -> [StoryFilter: CGImage] {
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let input = CIImage(cgImage: image)
        var out: [StoryFilter: CGImage] = [:]
        for f in StoryFilter.allCases {
            if let cg = ctx.createCGImage(f.apply(input), from: input.extent) { out[f] = cg }
        }
        return out
    }

    func tearDown() {
        PostMusic.shared.release(musicHolder)
        exportTask?.cancel()
        filterTask?.cancel()
        if sharer?.isSharing == true { sharer?.cancel() }
        tearDownVideo()
        display = nil
        filtered = nil
        drawingImage = nil
        images = [:]
    }

    private func tearDownVideo() {
        video?.tearDown()
        video = nil
    }

    // MARK: Undo

    /// Applies a change as one undo step.
    func commit(_ change: (inout StoryDoc) -> Void) {
        let before = doc
        change(&doc)
        recordChange(from: before)
    }

    private func recordChange(from before: StoryDoc) {
        guard doc != before else { return }
        undoStack.append(before)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        syncUndo()
        applied(from: before)
    }

    func undo() {
        guard editingText == nil, let last = undoStack.popLast() else { return }
        let before = doc
        redoStack.append(doc)
        doc = last
        syncUndo()
        applied(from: before)
    }

    func redo() {
        guard editingText == nil, let next = redoStack.popLast() else { return }
        let before = doc
        undoStack.append(doc)
        doc = next
        syncUndo()
        applied(from: before)
    }

    /// "Undo all": back to the picture as it was loaded (itself one undo step).
    func undoAll() {
        guard hasEdits else { return }
        mode = .normal
        selection = nil
        commit { $0 = original }
    }

    private func syncUndo() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    /// Keeps the derived things (drawing raster, filtered picture, video) in step with `doc`.
    private func applied(from before: StoryDoc) {
        if doc.strokes != before.strokes { redrawDrawing() }
        if doc.filter != before.filter { applyFilter() }
        if doc.trimStart != before.trimStart || doc.trimEnd != before.trimEnd { video?.setRange(doc.trimStart, doc.trimEnd) }
        if doc.muted != before.muted { video?.player.isMuted = doc.muted }
        if let s = selection, !doc.items.contains(where: { $0.id == s }) { selection = nil }
        let ids = Set(doc.items.map(\.id))
        images = images.filter { ids.contains($0.key) }
    }

    /// For a drag or pinch: everything between begin and end is one undo step.
    func beginGesture() {
        if gestureBefore == nil { gestureBefore = doc }
    }

    func endGesture() {
        guard let before = gestureBefore else { return }
        gestureBefore = nil
        recordChange(from: before)
    }

    /// A change during a gesture (no undo step of its own).
    func live(_ change: (inout StoryDoc) -> Void) {
        let before = doc
        change(&doc)
        if doc.trimStart != before.trimStart || doc.trimEnd != before.trimEnd {
            video?.scrub(to: doc.trimStart != before.trimStart ? doc.trimStart : doc.trimEnd)
        }
    }

    // MARK: Display

    func setDisplayPPU(_ ppu: CGFloat) {
        guard ppu > 0, abs(ppu - displayPPU) / displayPPU > 0.15 else { return }
        displayPPU = ppu
        images = [:]
        redrawDrawing()
    }

    /// A text item or sticker as an image, made again only when its content changes or it
    /// grows much bigger than it was drawn for.
    func image(for item: StoryItem) -> Piece? {
        let want = min(4, (displayPPU * max(1, item.scale) * 4).rounded(.up) / 4)
        if let c = images[item.id], c.kind == item.kind, c.ppu >= want * 0.8 { return c.piece }
        guard let r = StoryRenderer.image(of: item.kind, ppu: want) else { return nil }
        let piece = Piece(image: r.image, size: r.size, inset: r.inset)
        images[item.id] = (item.kind, want, piece)
        return piece
    }

    /// A piece's raster, its size in units, and the margin around what's visible.
    struct Piece {
        var image: CGImage
        var size: CGSize
        var inset: CGFloat
        var box: CGSize { CGSize(width: size.width - 2 * inset, height: size.height - 2 * inset) }
    }

    private func redrawDrawing() {
        drawingImage = StoryRenderer.drawing(doc.strokes, ppu: displayPPU)
    }

    private func applyFilter() {
        filterTask?.cancel()
        let filter = doc.filter
        video?.filter.value.withLock { $0 = filter }
        guard let display, filter != .normal else { filtered = nil; return }
        filterTask = Task {
            let image = await Self.filter(display, filter)
            if !Task.isCancelled, doc.filter == filter { filtered = image }
        }
    }

    nonisolated private static let filterContext = CIContext(options: [.cacheIntermediates: false])

    @concurrent
    private static func filter(_ image: CGImage, _ f: StoryFilter) async -> CGImage? {
        let input = CIImage(cgImage: image)
        return filterContext.createCGImage(f.apply(input), from: input.extent)
    }

    // MARK: Modes

    func setMode(_ m: Mode) {
        if case .text = mode, m != mode { finishText() }
        if m != .normal { selection = nil }
        mode = m
    }

    func toggle(_ m: Mode) {
        setMode(mode == m ? .normal : m)
    }

    // MARK: Text

    /// A new text item at `point` (canvas units), typed into at once.
    func addText(at point: CGPoint? = nil) {
        guard hasMedia, !isBusy else { return }
        if editingText != nil { finishText() }
        textBefore = doc
        textIsNew = true
        var t = lastText
        t.string = ""
        var item = StoryItem(kind: .text(t))
        if let point { item.center = point }
        doc.items.append(item)
        draft = t
        selection = nil
        mode = .text(item.id)
    }

    func editText(_ id: UUID) {
        guard let item = doc.items.first(where: { $0.id == id }), let t = item.text, !isBusy else { return }
        if editingText != nil { finishText() }
        textBefore = doc
        textIsNew = false
        draft = t
        selection = nil
        mode = .text(id)
    }

    /// Ends typing: the text goes onto its item (an empty one is removed), as one undo step.
    func finishText() {
        guard case .text(let id) = mode else { return }
        mode = .normal
        let before = textBefore ?? doc
        textBefore = nil
        guard let i = doc.items.firstIndex(where: { $0.id == id }) else { return }
        if draft.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            doc.items.remove(at: i)
        } else {
            doc.items[i].kind = .text(draft)
            lastText = draft
            selection = id
        }
        if textIsNew && doc.items.count == before.items.count { doc = before }
        recordChange(from: before)
    }

    // MARK: Stickers

    func addSticker(_ emoji: String) {
        guard hasMedia else { return }
        var item = StoryItem(kind: .sticker(emoji))
        // A little off centre each time, so several don't stack exactly.
        let n = CGFloat(doc.items.count % 5)
        item.center = CGPoint(x: StoryDoc.size.width / 2 + (n - 2) * 36, y: StoryDoc.size.height * 0.42 + n * 30)
        item.rotation = Double(n - 2) * 0.06
        commit { $0.items.append(item) }
        mode = .normal
        selection = item.id
    }

    // MARK: Items

    func delete(_ id: UUID) {
        commit { $0.items.removeAll { $0.id == id } }
        if selection == id { selection = nil }
    }

    func bringToFront(_ id: UUID) {
        guard let i = doc.items.firstIndex(where: { $0.id == id }), i < doc.items.count - 1 else { return }
        commit { d in d.items.append(d.items.remove(at: i)) }
    }

    func nudge(_ id: UUID, by d: CGSize) {
        commit { doc in
            guard let i = doc.items.firstIndex(where: { $0.id == id }) else { return }
            doc.items[i].center.x += d.width
            doc.items[i].center.y += d.height
        }
    }

    // MARK: Drawing

    func addStroke(_ points: [CGPoint]) {
        guard !points.isEmpty else { return }
        let s = StoryStroke(brush: brush, color: brushColor, width: StoryStroke.widths[brushWidth], points: points)
        commit { $0.strokes.append(s) }
    }

    func setFilter(_ f: StoryFilter) {
        commit { $0.filter = f }
    }

    func stepFilter(_ by: Int) {
        let all = StoryFilter.allCases
        guard let i = all.firstIndex(of: doc.filter) else { return }
        setFilter(all[(i + by + all.count) % all.count])
    }

    func toggleSound() {
        commit { $0.muted.toggle() }
        playMusic()
    }

    // MARK: Sharing

    /// Hands the canvas to a background upload and closes: it's flattened and shared in the
    /// corner while you carry on (`UploadJob`).
    func share() {
        guard let source, !isBusy else { return }
        if editingText != nil { finishText() }
        mode = .normal
        selection = nil
        video?.pause()
        app?.shareStoryInBackground(source: source, doc: doc, gradient: gradient, reshare: placedReshare)
    }

    /// The reshare with the card's place on the finished story (where it was moved and zoomed to).
    private var placedReshare: StoryReshare? {
        guard var reshare, let source else { return nil }
        let r = doc.bgRect(aspect: source.aspect), c = StoryDoc.size
        reshare.placement = .init(x: r.midX / c.width, y: r.midY / c.height, width: r.width / c.width, height: r.height / c.height)
        return reshare
    }

    func cancelShare() {
        exportTask?.cancel()
        sharer?.cancel()
        export = .idle
        video?.play()
    }

    /// Exports and waits (debug: writes the file without sharing).
    func exportOnly() async throws -> PreparedMedia? {
        guard let source else { return nil }
        if source.isVideo { return try await StoryExport.video(source, doc: doc, gradient: gradient) }
        return try await StoryExport.photo(source, doc: doc, gradient: gradient)
    }

    // MARK: Closing

    func requestClose() {
        if editingText != nil { finishText(); return }
        if mode != .normal { mode = .normal; return }
        if hasEdits || isBusy { confirmingClose = true; return }
        app?.closeStoryEditor()
    }

    func close() {
        app?.closeStoryEditor()
    }

    #if DEBUG
    /// Debug: replaces the document (sample content for screenshots).
    func debugSet(_ change: (inout StoryDoc) -> Void) { commit(change) }

    /// Debug dry runs: shares and waits for the outcome.
    func shareAndWait() async {
        // The same background upload, without an app (the create probe).
        guard let source else { return }
        let job = UploadJob(story: source, doc: doc, gradient: gradient, reshare: placedReshare, app: nil, client: client)
        await job.waitUntilDone()
        sharer = job.sharer
        if job.sharer == nil, case .failed(let m) = job.state { export = .failed(m) }
    }
    #endif
}

// MARK: - Video

nonisolated final class FilterBox: Sendable {
    let value = Mutex<StoryFilter>(.normal)
}

/// The background video: loops the kept part, with the filter applied as it plays.
@Observable
final class StoryVideo {
    let player: AVPlayer
    /// Read on the video's render thread for each frame.
    let filter = FilterBox()
    private(set) var time: Double = 0
    @ObservationIgnored private var start: Double = 0
    @ObservationIgnored private var end: Double
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var playing = true

    init(url: URL, end: Double) {
        self.end = end
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4
        item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        let box = filter
        Task { [weak self] in
            // Filtered as it plays: the same presets the export uses, at the video's own size.
            // (Without it the video still plays, just unfiltered.)
            if let comp = try? await AVVideoComposition.videoComposition(with: asset, applyingCIFiltersWithHandler: { request in
                let f = box.value.withLock { $0 }
                request.finish(with: f.apply(request.sourceImage), context: nil)
            }) {
                item.videoComposition = comp
            }
            self?.play()
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loop() }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.time = t.seconds }
        }
    }

    private func loop() {
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if playing { player.play() }
    }

    func play() { playing = true; player.play() }
    func pause() { playing = false; player.pause() }

    /// Shows the frame at `t` (dragging a trim handle).
    func scrub(to t: Double) {
        player.pause()
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRange(_ s: Double, _ e: Double) {
        start = s
        end = e
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: e, preferredTimescale: 600)
        loop()
    }

    func tearDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }
}
