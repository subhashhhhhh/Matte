import SwiftUI
import OSLog

/// The create sheet: picked files (reorderable), one crop for all of them with each item
/// placed by dragging, a caption and options, where it goes, and the share itself — prepare,
/// upload, publish — with progress. A failed share keeps what's done (rendered files and
/// finished uploads), so Retry picks up where it stopped.
@Observable
final class CreateModel {
    enum Target: String, CaseIterable, Identifiable {
        case post, reel, story
        var id: String { rawValue }
        var title: String {
            switch self {
            case .post: "Post"
            case .reel: "Reel"
            case .story: "Story"
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        var source: CreateSource
        /// Where the crop sits, as the centre of the kept part (0…1 on each axis).
        var center = CGPoint(x: 0.5, y: 0.5)
        var thumb: CGImage?

        static func == (a: Item, b: Item) -> Bool { a.id == b.id && a.center == b.center && a.thumb === b.thumb }
    }

    enum Phase: Equatable {
        case editing
        case sharing
        case failed(String)
    }

    static let captionLimit = 2200

    private(set) var items: [Item] = []
    var selectedId: UUID?
    var shape: CropShape = .original
    var caption = ""
    var hideCounts = false
    var commentsOff = false
    /// Manager mode: Instagram publishes it at this time instead of now (nil: share now).
    var scheduleAt: Date?
    var target: Target = .post {
        didSet { if target != oldValue { fitShape() } }
    }
    private(set) var phase: Phase = .editing
    /// 0…1 while sharing.
    private(set) var progress: Double = 0
    private(set) var status = ""
    /// A problem with the picked files (shown under the canvas).
    private(set) var notice: String?
    /// The selected item's still at canvas size (only one is kept).
    private(set) var canvasImage: CGImage?
    private(set) var loading = false

    /// Stories have their own editor: the sheet offers only Post and Reel. The story editor
    /// (and the debug dry runs) turn this on to share a story through the same steps.
    @ObservationIgnored var allowsStory = false
    /// A post or reel added to the story (a tappable sticker over its card).
    @ObservationIgnored private var storyReshare: StoryReshare?
    /// Called after a successful share in place of closing the create sheet (the story editor).
    @ObservationIgnored var onShared: (() -> Void)?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let client: IGClient
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Work already done for the current settings (kept for Retry).
    @ObservationIgnored private var prepared: [UUID: PreparedMedia] = [:]
    @ObservationIgnored private var uploaded: [UUID: String] = [:]
    @ObservationIgnored private var preparedKey: String?
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Instagram", category: "Create")

    init(app: AppModel?, client: IGClient) {
        self.app = app
        self.client = client
    }

    var selected: Item? { items.first { $0.id == selectedId } ?? items.first }
    var isVideo: Bool { items.first?.source.isVideo ?? false }
    var isSharing: Bool { phase == .sharing }

    /// Where these files can go: a single video is a reel or a story; photos are a post (a
    /// carousel when there are several); one photo can also be a story.
    var targets: [Target] {
        guard let first = items.first else { return allowsStory ? [.post, .reel, .story] : [.post, .reel] }
        if first.source.isVideo {
            let seconds = Double(first.source.durationMs ?? 0) / 1000
            return allowsStory && seconds <= CreateMedia.maxStorySeconds ? [.reel, .story] : [.reel]
        }
        return allowsStory && items.count == 1 ? [.post, .story] : [.post]
    }

    var shapes: [CropShape] {
        switch target {
        case .story: [.tall]
        case .reel: [.original, .square, .portrait, .landscape, .tall]
        case .post: [.original, .square, .portrait, .landscape]
        }
    }

    /// The crop's width over height ("Original" is the first item's shape, kept within what
    /// Instagram accepts).
    var ratio: CGFloat {
        let original = items.first?.source.aspect ?? 1
        let range = target == .post ? CreateMedia.photoAspects : CreateMedia.reelAspects
        return min(max(shape.ratio(original: original), range.lowerBound), range.upperBound)
    }

    var canShare: Bool {
        !items.isEmpty && targets.contains(target) && caption.count <= Self.captionLimit && !isSharing
            && (!isScheduling || scheduleAt.map(SchedulePicker.isAllowed) == true)
    }

    /// What can be scheduled so far: a single photo post (the only scheduled publish recorded),
    /// in Manager mode.
    var canSchedule: Bool { app?.managerMode == true && target == .post && items.count <= 1 && !isVideo }
    /// This share is a scheduled one.
    var isScheduling: Bool { canSchedule && scheduleAt != nil && !items.isEmpty }

    // MARK: Files

    func add(_ urls: [URL]) async {
        notice = nil
        loading = true
        defer { loading = false }
        for url in urls {
            do {
                let source = try await CreateMedia.read(url)
                if let first = items.first {
                    if source.isVideo || first.source.isVideo {
                        notice = "A reel or story is one video on its own; a carousel holds photos only."
                        continue
                    }
                    if items.count >= CreateMedia.maxItems {
                        notice = "A post holds up to \(CreateMedia.maxItems) photos."
                        break
                    }
                }
                var item = Item(source: source)
                item.thumb = await CreateMedia.still(source, maxPixels: 180)
                items.append(item)
                if selectedId == nil { selectedId = item.id }
            } catch {
                notice = error.localizedDescription
            }
        }
        if !targets.contains(target) { target = targets[0] } else { fitShape() }
        resetWork()
        await loadCanvas()
    }

    func remove(_ id: UUID) {
        guard !isSharing else { return }
        items.removeAll { $0.id == id }
        if selectedId == id { selectedId = items.first?.id }
        if !items.isEmpty, !targets.contains(target) { target = targets[0] }
        resetWork()
        Task { await loadCanvas() }
    }

    /// Moves an item one place left or right (carousel order).
    func move(_ id: UUID, by delta: Int) {
        guard !isSharing, let i = items.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard items.indices.contains(j) else { return }
        items.swapAt(i, j)
        resetWork()
    }

    /// Moves `id` to where `target` is (drag to reorder).
    func move(_ id: UUID, before other: UUID) {
        guard !isSharing, id != other, let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == other }) else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
        resetWork()
    }

    func select(_ id: UUID) {
        guard selectedId != id else { return }
        selectedId = id
        Task { await loadCanvas() }
    }

    func setCenter(_ point: CGPoint, for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        // Kept where the crop can actually go, so dragging back responds at once.
        let rect = CreateMedia.cropRect(sourceAspect: items[i].source.aspect, ratio: ratio, center: point)
        items[i].center = CGPoint(x: rect.midX, y: rect.midY)
        prepared[id] = nil
        uploaded[id] = nil
    }

    func cropRect(for item: Item) -> CGRect {
        CreateMedia.cropRect(sourceAspect: item.source.aspect, ratio: ratio, center: item.center)
    }

    private func fitShape() {
        if !shapes.contains(shape) { shape = shapes[0] }
    }

    private func loadCanvas() async {
        guard let item = selected else { canvasImage = nil; return }
        let id = item.id
        let image = await CreateMedia.still(item.source, maxPixels: 1400)
        if selected?.id == id { canvasImage = image }
    }

    /// Settings that change the rendered files: a change means rendering and uploading again.
    private var workKey: String {
        "\(target.rawValue)|\(shape.rawValue)|\(items.map { "\($0.id)@\($0.center.x),\($0.center.y)" }.joined(separator: ";"))"
    }

    private func resetWork() {
        prepared = [:]
        uploaded = [:]
        preparedKey = nil
    }

    // MARK: Sharing

    func share() {
        guard canShare else { return }
        if preparedKey != workKey { resetWork(); preparedKey = workKey }
        phase = .sharing
        progress = 0
        status = "Preparing…"
        task = Task { await run() }
    }

    func cancel() {
        task?.cancel()
    }

    /// Shares a story that's already finished (the story editor's flattened 1080×1920 file):
    /// no crop or re-encode, straight to the same upload and `configure_to_story` as before.
    /// Try Again after a failure is `share()`, which keeps the finished uploads.
    func shareFinishedStory(_ media: PreparedMedia, isVideo: Bool, reshare: StoryReshare? = nil) {
        guard !isSharing else { return }
        storyReshare = reshare
        allowsStory = true
        resetWork()
        let source = CreateSource(url: media.file, isVideo: isVideo, width: media.width, height: media.height, durationMs: media.durationMs)
        let item = Item(source: source)
        items = [item]
        selectedId = item.id
        target = .story
        preparedKey = workKey
        prepared[item.id] = media
        share()
    }

    /// Shares and waits for the outcome (debug dry runs).
    func shareAndWait() async {
        share()
        await task?.value
    }

    /// Waits for a share already under way (debug dry runs of the story editor).
    func waitForShare() async {
        await task?.value
    }

    private func run() async {
        let options = IGClient.PostOptions(caption: caption, hideCounts: hideCounts, commentsOff: commentsOff,
                                           scheduledAt: isScheduling ? scheduleAt : nil)
        do {
            let media: Media?
            switch target {
            case .post: media = try await sharePost(options)
            case .reel: media = try await shareReel(options)
            case .story: media = try await shareStory()
            }
            finish(media)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                phase = .editing
                return
            }
            if case IGError.signedOut = error { app?.report(error); phase = .editing; return }
            log.error("Share failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Progress is split: preparing takes the first 15 %, uploads up to 85 %, publishing the rest.
    private func prepareAll(coverAt: Double) async throws {
        let todo = items.filter { prepared[$0.id] == nil }
        for (n, item) in todo.enumerated() {
            try Task.checkCancellation()
            status = items.count > 1 ? "Preparing \(n + 1) of \(todo.count)…" : (item.source.isVideo ? "Preparing video…" : "Preparing…")
            let crop = cropRect(for: item)
            let base = Double(n) / Double(max(todo.count, 1))
            let r = ratio
            if item.source.isVideo {
                prepared[item.id] = try await CreateMedia.renderVideo(item.source, crop: crop, ratio: r, coverAt: coverAt) { [weak self] p in
                    Task { @MainActor in self?.progress = 0.15 * (base + p / Double(max(todo.count, 1))) }
                }
            } else {
                prepared[item.id] = try await CreateMedia.renderPhoto(item.source, crop: crop, ratio: r)
            }
            progress = 0.15 * Double(n + 1) / Double(max(todo.count, 1))
        }
        progress = 0.15
    }

    /// Bytes sent so far across the uploads, as a share of 15…85 %.
    private func uploadProgress(done: Int64, total: Int64) {
        progress = 0.15 + 0.7 * Double(done) / Double(max(total, 1))
    }

    private func sharePost(_ options: IGClient.PostOptions) async throws -> Media? {
        try await prepareAll(coverAt: 0.01)
        let files = items.compactMap { prepared[$0.id] }
        let total = Int64(files.reduce(0) { $0 + $1.bytes })
        var done: Int64 = files.indices.filter { uploaded[items[$0].id] != nil }.reduce(0) { $0 + Int64(files[$1].bytes) }
        for (n, item) in items.enumerated() where uploaded[item.id] == nil {
            try Task.checkCancellation()
            guard let file = prepared[item.id] else { continue }
            status = items.count > 1 ? "Uploading \(n + 1) of \(items.count)…" : "Uploading…"
            let id = IGClient.newUploadId()
            let start = done
            try await client.uploadPhoto(file.file, uploadId: id, entity: "fb_uploader_" + id, width: file.width, height: file.height,
                                         progress: progressReporter(start: start, total: total))
            uploaded[item.id] = id
            done += Int64(file.bytes)
            uploadProgress(done: done, total: total)
        }
        status = options.scheduledAt == nil ? "Sharing…" : "Scheduling…"
        progress = 0.9
        let ids = items.compactMap { uploaded[$0.id] }
        if ids.count == 1 { return try await client.configurePhoto(uploadId: ids[0], options: options) }
        return try await client.configureSidecar(uploadIds: ids, options: options)
    }

    private func shareReel(_ options: IGClient.PostOptions) async throws -> Media? {
        guard let item = items.first else { return nil }
        try await prepareAll(coverAt: 0.01)
        guard let file = prepared[item.id], let cover = file.cover else { return nil }
        if uploaded[item.id] == nil {
            let id = IGClient.newUploadId()
            let total = Int64(file.bytes)
            status = "Uploading video…"
            try await client.uploadReelVideo(file.file, uploadId: id, durationMs: file.durationMs ?? 0, width: file.width, height: file.height,
                                             progress: progressReporter(start: 0, total: total))
            status = "Uploading cover…"
            let videoBytes = total - Int64((try? cover.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            // The cover goes up as a photo of media type 2, named and sized like the video (recorded).
            try await client.uploadPhoto(cover, uploadId: id, entity: "fb_uploader_" + id, width: file.width, height: file.height,
                                         mediaType: 2, progress: progressReporter(start: videoBytes, total: total))
            uploaded[item.id] = id
        }
        status = "Sharing…"
        progress = 0.88
        guard let id = uploaded[item.id] else { return nil }
        return try await client.configureClips(uploadId: id, options: options) { [weak self] in
            Task { @MainActor in self?.status = "Instagram is processing the video…" }
        }
    }

    private func shareStory() async throws -> Media? {
        guard let item = items.first else { return nil }
        try await prepareAll(coverAt: 1)
        guard let file = prepared[item.id] else { return nil }
        if uploaded[item.id] == nil {
            let total = Int64(file.bytes)
            status = "Uploading…"
            if item.source.isVideo, let cover = file.cover {
                // `PolarisStoryCreationActions`: upload id = the time, entity "story_<id>".
                let id = IGClient.newUploadId()
                try await client.uploadStoryVideo(file.file, uploadId: id, entity: "story_" + id, durationMs: file.durationMs ?? 0,
                                                  width: file.width, height: file.height, progress: progressReporter(start: 0, total: total))
                let videoBytes = total - Int64((try? cover.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                try await client.uploadPhoto(cover, uploadId: id, entity: "story_" + id, width: file.width, height: file.height,
                                             mediaType: 2, mobile: true, progress: progressReporter(start: videoBytes, total: total))
                uploaded[item.id] = id
            } else {
                let id = IGClient.newUploadId()
                try await client.uploadPhoto(file.file, uploadId: id, entity: "fb_uploader_" + id, width: file.width, height: file.height,
                                             mobile: true, progress: progressReporter(start: 0, total: total))
                uploaded[item.id] = id
            }
        }
        status = "Adding to your story…"
        progress = 0.9
        guard let id = uploaded[item.id] else { return nil }
        // A shared post: the phone app's endpoint keeps the tappable sticker (instagram.com's
        // drops it). If the phone request fails, publish the normal way and say so.
        if let reshare = storyReshare, !item.source.isVideo {
            do {
                let media = prepared[item.id]
                return try await client.configureReshareStoryByPhone(uploadId: id, width: media?.width ?? 1080,
                                                                     height: media?.height ?? 1920, reshare: reshare)
            } catch {
                if error is CancellationError { throw error }
                #if DEBUG
                if case IGError.http(-1, _) = error { throw error }  // dry run
                #endif
                log.error("Phone story publish failed: \(error.localizedDescription, privacy: .public)")
                app?.show("Posting without the tappable post (Instagram refused it)")
            }
        }
        return try await client.configureStory(uploadId: id, isVideo: item.source.isVideo, reshare: storyReshare) { [weak self] in
            Task { @MainActor in self?.status = "Instagram is processing the video…" }
        }
    }

    private func progressReporter(start: Int64, total: Int64) -> @Sendable (Int64) -> Void {
        { [weak self] sent in
            Task { @MainActor in self?.uploadProgress(done: start + sent, total: total) }
        }
    }

    private func finish(_ media: Media?) {
        progress = 1
        let scheduled = isScheduling ? scheduleAt : nil
        let message: String
        if let scheduled {
            message = "Scheduled for " + scheduled.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        } else {
            message = switch target {
            case .post: "Shared to your profile"
            case .reel: "Your reel is shared"
            case .story: "Added to your story"
            }
        }
        if scheduled != nil { app?.planner?.didSchedule() } else { app?.created(media, story: target == .story) }
        app?.show(message)
        for p in prepared.values {
            try? FileManager.default.removeItem(at: p.file)
            if let c = p.cover { try? FileManager.default.removeItem(at: c) }
        }
        resetWork()
        if let onShared { onShared() } else { app?.closeCreate() }
    }
}
