import SwiftUI

/// A post, reel or story being shared in the background: the sheet or story editor closes as
/// soon as you press Share, and this carries on (exporting the story, uploading, publishing)
/// while you use the app. Shown as a thumbnail with a progress ring in the corner.
@Observable
final class UploadJob: Identifiable {
    enum State: Equatable { case working, failed(String), done }

    let id = UUID()
    let title: String
    private(set) var thumbnail: CGImage?
    private(set) var state: State = .working
    /// Exporting the story editor's canvas, before the upload (0…1).
    private(set) var exportProgress: Double?
    private(set) var sharer: CreateModel?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let client: IGClient
    @ObservationIgnored private var task: Task<Void, Never>?
    /// The story editor's work, kept so Try Again doesn't export again.
    @ObservationIgnored private var story: (source: CreateSource, doc: StoryDoc, gradient: StoryExport.Gradient, reshare: StoryReshare?)?
    @ObservationIgnored private var exported: PreparedMedia?

    var progress: Double {
        if let exportProgress { return 0.15 * exportProgress }
        return max(sharer?.progress ?? 0, 0.15)
    }

    var status: String {
        switch state {
        case .failed(let m): m
        case .done: "Done"
        case .working: exportProgress != nil ? "Preparing your story…" : (sharer?.status.isEmpty == false ? sharer!.status : "Uploading…")
        }
    }

    /// A post or reel from the create sheet, already set up: shares it (or carries on sharing).
    init(sheet model: CreateModel, app: AppModel, client: IGClient) {
        self.app = app
        self.client = client
        title = model.target == .reel ? "Reel" : model.isScheduling ? "Scheduled post" : "Post"
        sharer = model
        attach(model)
        if let first = model.items.first?.source { loadThumbnail(first) }
        if !model.isSharing { model.share() }
        watch()
    }

    /// A story from the editor: exports the canvas, then uploads it.
    init(story source: CreateSource, doc: StoryDoc, gradient: StoryExport.Gradient, reshare: StoryReshare? = nil,
         app: AppModel?, client: IGClient) {
        self.app = app
        self.client = client
        title = "Story"
        story = (source, doc, gradient, reshare)
        loadThumbnail(source)
        start()
    }

    func retry() {
        guard case .failed = state else { return }
        state = .working
        if let sharer, exported != nil || story == nil {
            sharer.share()  // keeps finished uploads
            watch()
        } else {
            start()
        }
    }

    /// Stops without touching the list (the account is going away).
    func cancelQuietly() {
        task?.cancel()
        sharer?.cancel()
    }

    func discard() {
        task?.cancel()
        sharer?.cancel()
        app?.uploads.removeAll { $0.id == id }
        MemoryRelief.soon()
    }

    /// A failed post or reel: back into the sheet to change something.
    var canReopen: Bool { story == nil }

    func reopen() {
        guard canReopen, let sharer, let app, app.creating == nil else { return }
        sharer.onShared = nil
        app.uploads.removeAll { $0.id == id }
        app.reopenCreate(sharer)
    }

    private func attach(_ model: CreateModel) {
        model.onShared = { [weak self] in self?.finished() }
    }

    private func start() {
        guard let story else { return }
        exportProgress = 0
        task = Task {
            do {
                let report: @Sendable (Double) -> Void = { [weak self] p in
                    Task { @MainActor in if self?.exportProgress != nil { self?.exportProgress = p } }
                }
                let media = try await story.source.isVideo
                    ? StoryExport.video(story.source, doc: story.doc, gradient: story.gradient, progress: report)
                    : StoryExport.photo(story.source, doc: story.doc, gradient: story.gradient)
                try Task.checkCancellation()
                #if DEBUG
                DebugStoryEditor.keep(media)
                #endif
                exported = media
                exportProgress = nil
                let model = CreateModel(app: app, client: client)
                attach(model)
                sharer = model
                model.shareFinishedStory(media, isVideo: story.source.isVideo, reshare: story.reshare)
                watch()
            } catch is CancellationError {
            } catch {
                exportProgress = nil
                state = .failed(error.localizedDescription)
            }
            MemoryRelief.soon()
        }
    }

    /// Follows the sharer until it fails (it reports success through `onShared`).
    private func watch() {
        guard let sharer else { return }
        task = Task { [weak self] in
            await sharer.waitForShare()
            guard let self, self.state == .working else { return }
            if case .failed(let m) = sharer.phase { self.state = .failed(m) }
        }
    }

    private func finished() {
        state = .done
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard let self else { return }
            self.app?.uploads.removeAll { $0.id == self.id }
        }
    }

    private func loadThumbnail(_ source: CreateSource) {
        Task { [weak self] in
            let image = await CreateMedia.still(source, maxPixels: 160)
            self?.thumbnail = image
        }
    }

    #if DEBUG
    func waitUntilDone() async {
        while state == .working { try? await Task.sleep(for: .milliseconds(200)) }
    }
    #endif
}

/// The uploads in the bottom-right corner: a thumbnail with a ring filling as it uploads; a
/// failed one turns red and offers Try Again.
struct UploadsCorner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(app.uploads) { job in
                UploadBadge(job: job)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(20)
        .animation(Motion.pop, value: app.uploads.map(\.id))
    }
}

private struct UploadBadge: View {
    let job: UploadJob
    @State private var hovering = false

    private var failed: Bool { if case .failed = job.state { true } else { false } }
    private var done: Bool { job.state == .done }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if hovering || failed {
                card.transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            ring
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: failed)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(failed ? "Couldn't share your \(job.title.lowercased())" : done ? "\(job.title) shared" : "Sharing your \(job.title.lowercased())")
                .font(.system(size: 12.5, weight: .semibold))
            if !done {
                Text(failed ? job.status : "\(job.status) \(Int(job.progress * 100))%")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if failed {
                    Button("Try Again") { job.retry() }.buttonStyle(.prominentCompact)
                    if job.canReopen { Button("Edit") { job.reopen() }.buttonStyle(SecondaryPillStyle()) }
                    Button("Discard") { job.discard() }.buttonStyle(SecondaryPillStyle())
                } else if !done {
                    Button("Cancel") { job.discard() }.buttonStyle(SecondaryPillStyle())
                }
            }
        }
        .frame(width: 230, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.background))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.panelStroke))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
    }

    private var ring: some View {
        ZStack {
            Circle().fill(Theme.panel)
            if let image = job.thumbnail {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 40, height: 40).clipShape(Circle())
                    .opacity(done ? 0.5 : 1)
            }
            if done {
                Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
            } else if failed {
                Image(systemName: "exclamationmark").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(Circle().fill(.black.opacity(0.45)))
            }
            Circle().stroke(Color.primary.opacity(0.15), lineWidth: 3)
            Circle()
                .trim(from: 0, to: failed || done ? 1 : job.progress)
                .stroke(failed ? Theme.like : done ? Color.green : Theme.link, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: job.progress)
        }
        .frame(width: 48, height: 48)
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
        .help(job.status)
    }
}
