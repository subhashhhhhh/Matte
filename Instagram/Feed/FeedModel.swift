import SwiftUI

/// Which of Instagram's home feeds to show (the web app's For you / Following / Favorites).
nonisolated enum FeedSource: String, CaseIterable, Identifiable, Sendable {
    case forYou = "home", following, favorites
    var id: String { rawValue }
    var title: String {
        switch self {
        case .forYou: "For you"
        case .following: "Following"
        case .favorites: "Favorites"
        }
    }
}

/// Which kinds of posts Home shows.
enum FeedFilter: String, CaseIterable, Identifiable {
    case all, photos, videos, carousels
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .photos: "Photos"
        case .videos: "Videos"
        case .carousels: "Carousels"
        }
    }

    func matches(_ m: Media) -> Bool {
        switch self {
        case .all: true
        case .photos: m.children.count <= 1 && !m.isVideo
        case .videos: m.children.count <= 1 && m.isVideo
        case .carousels: m.children.count > 1
        }
    }
}

/// The home feed and the stories tray above it.
@Observable
final class FeedModel {
    private(set) var posts: [Media] = []
    private(set) var tray: [StoryReel] = []
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private var cursor: String?
    private var hasMore = true
    /// Remembered between launches.
    var source: FeedSource = FeedSource(rawValue: UserDefaults.standard.string(forKey: "feedSource") ?? "") ?? .forYou {
        didSet {
            guard source != oldValue else { return }
            UserDefaults.standard.set(source.rawValue, forKey: "feedSource")
            closeOpened()
            // Each feed keeps what it had loaded: switching back shows it at once.
            saved[oldValue] = SourceState(posts: posts, cursor: cursor, hasMore: hasMore, fetchedAt: fetchedAt, stale: stale)
            let restored = saved[source]
            posts = restored?.posts ?? []
            cursor = restored?.cursor
            hasMore = restored?.hasMore ?? true
            fetchedAt = restored?.fetchedAt ?? .distantPast
            stale = restored?.stale ?? false
            // Never loaded this launch: the copy saved on disk, until the fresh one arrives.
            if restored == nil { showCached() }
            Task {
                // A load for the previous feed may still be running: let it finish (its result
                // is dropped), then load this one (quietly, if it's only getting stale).
                while isLoading || isLoadingMore { try? await Task.sleep(for: .milliseconds(100)) }
                if posts.isEmpty || stale || Date.now.timeIntervalSince(fetchedAt) > 300 { await refresh() }
            }
        }
    }
    var filter: FeedFilter = .all {
        didSet {
            closeOpened()
            Task { await fillForFilter() }
        }
    }

    /// The loaded posts that pass the filter, in the feed's own order (what the grid shows).
    var visible: [Media] { posts.filter(filter.matches) }

    /// A narrow filter can leave the grid nearly empty: load a few more pages to fill it.
    private func fillForFilter() async {
        var tries = 0
        while visible.count < 8, hasMore, tries < 4 {
            tries += 1
            await loadMore()
        }
    }

    private struct SourceState {
        var posts: [Media]
        var cursor: String?
        var hasMore: Bool
        var fetchedAt: Date
        var stale: Bool
    }
    @ObservationIgnored private var saved: [FeedSource: SourceState] = [:]
    @ObservationIgnored private var fetchedAt = Date.distantPast

    /// Starts loading a post's comments ahead of a likely click (its tile is hovered).
    func prewarm(_ media: Media) {
        let detail = MediaDetailModel.cached(pk: media.pk, media: media, client: client)
        Task { await detail.start() }
    }

    /// Debug only: asks the view to open this post (with its animation).
    var debugOpenRequest: Int?

    /// Post whose video is previewing in the grid (one at a time).
    var playing: String?
    /// The post opened large over the grid, and where it sits in `posts`.
    private(set) var opened: MediaDetailModel?
    private(set) var openedIndex: Int?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let client: IGClient
    @ObservationIgnored private var loadedOnce = false
    /// `posts` came from the disk cache: no cursor yet, page 1 must load before paging on.
    @ObservationIgnored private(set) var stale = false
    /// The grid is scrolled down (set by the view): fresh results mustn't replace what's shown.
    @ObservationIgnored var scrolledAway = false
    private var cache: ResponseCache? { app?.cache }
    static let cachedPosts = 24

    init(app: AppModel, client: IGClient) {
        self.app = app
        self.client = client
    }

    func loadIfNeeded() async {
        guard !loadedOnce else { return }
        loadedOnce = true
        showCached()
        await refresh()
    }

    /// Shows the last first page saved on disk (and the stories tray) until the fresh one arrives.
    private func showCached() {
        guard let cache else { return }
        if posts.isEmpty, let hit = cache.load([Media].self, "feed-" + source.rawValue)?.value.cacheable(Self.cachedPosts), !hit.isEmpty {
            posts = hit
            stale = true
        }
        if tray.isEmpty, let hit = cache.load([StoryReel].self, "tray", maxAge: 86_400)?.value {
            tray = hit
        }
    }

    /// Takes in a fresh first page. Over posts the user is looking at (scrolled down, or a post
    /// open) it's added after them instead, so nothing moves; otherwise it replaces them
    /// (unchanged posts keep their identity, so their tiles stay put).
    /// Returns whether the shown list was replaced.
    private func adopt(_ fresh: [Media]) -> Bool {
        defer { stale = false }
        if !posts.isEmpty, scrolledAway || opened != nil {
            let known = Set(posts.map(\.pk))
            posts += fresh.filter { !known.contains($0.pk) }
            return false
        }
        posts = fresh
        return true
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let trayTask = try? client.storyTray()
        let requested = source
        var replaced = false
        var firstPage: [Media]?
        do {
            let page = try await client.homeFeed(source: requested)
            guard requested == source else { return }
            // A failed refresh keeps what's shown.
            replaced = adopt(page.items)
            cursor = page.cursor
            hasMore = page.hasMore
            fetchedAt = .now
            loadFailed = false
            firstPage = page.items
        } catch {
            loadFailed = posts.isEmpty
            app?.report(error)
        }
        if var t = await trayTask {
            // Your own story first, as "Your story" (the tray doesn't always include it).
            if let me = app?.me, me.latestStory != nil, !t.contains(where: { $0.user.id == me.id }) {
                t.insert(StoryReel(id: me.id, user: me, seen: true), at: 0)
            }
            tray = t
            cache?.save(t.map { var r = $0; r.items = []; return r }, "tray")
        }
        // Feed pages are short (ads and suggestions are left out): fill a few grid rows.
        var tries = 0
        while posts.count < 8, hasMore, tries < 3 {
            tries += 1
            await loadMore()
        }
        if let firstPage, requested == source {
            cache?.save((replaced ? posts : firstPage).cacheable(Self.cachedPosts), "feed-" + requested.rawValue)
        }
        #if DEBUG
        // `-IGOpen post|story`: open the first post or a story on launch (for screenshots).
        switch UserDefaults.standard.string(forKey: "IGOpen") {
        case "post":
            try? await Task.sleep(for: .seconds(3))
            debugOpenRequest = 0
        case "story": app?.openStories(tray, at: min(3, max(0, tray.count - 1)))
        default: break
        }
        #endif
    }

    func loadMore() async {
        // Posts from the disk cache have no cursor: load page 1 first (`refresh` keeps them in place).
        if stale { return await refresh() }
        guard hasMore, let cursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let requested = source
            let page = try await client.homeFeed(after: cursor, source: requested)
            guard requested == source else { return }
            let known = Set(posts.map(\.pk))
            posts += page.items.filter { !known.contains($0.pk) }
            // A failed "load more" keeps its cursor so it can be retried.
            self.cursor = page.cursor
            hasMore = page.hasMore && page.cursor != nil
        } catch {
            app?.report(error)
        }
    }

    private(set) var isLoadingMore = false

    func open(at index: Int) {
        let shown = visible
        guard shown.indices.contains(index) else { return }
        playing = nil
        openedIndex = index
        opened = MediaDetailModel.cached(pk: shown[index].pk, media: shown[index], client: client)
        if shown.count - index < 4 { Task { await loadMore() } }
    }

    func step(_ delta: Int) {
        guard let i = openedIndex else { return }
        open(at: i + delta)
    }

    func closeOpened() {
        opened = nil
        openedIndex = nil
        MemoryRelief.soon()
    }

    /// Marks a reel in the tray seen after it was watched.
    func markSeen(_ reelId: String) {
        guard let i = tray.firstIndex(where: { $0.id == reelId }) else { return }
        tray[i].seen = true
    }
}
