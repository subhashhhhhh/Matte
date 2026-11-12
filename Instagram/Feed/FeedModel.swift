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
            posts = []
            cursor = nil
            hasMore = true
            Task {
                // A load for the previous feed may still be running: let it finish (its result
                // is dropped), then load this one.
                while isLoading || isLoadingMore { try? await Task.sleep(for: .milliseconds(100)) }
                await refresh()
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

    /// Post whose video is previewing in the grid (one at a time).
    var playing: String?
    /// The post opened large over the grid, and where it sits in `posts`.
    private(set) var opened: MediaDetailModel?
    private(set) var openedIndex: Int?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let client: IGClient
    @ObservationIgnored private var loadedOnce = false

    init(app: AppModel, client: IGClient) {
        self.app = app
        self.client = client
    }

    func loadIfNeeded() async {
        guard !loadedOnce else { return }
        loadedOnce = true
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let trayTask = try? client.storyTray()
        do {
            let requested = source
            let page = try await client.homeFeed(source: requested)
            guard requested == source else { return }
            // A failed refresh keeps what's shown.
            posts = page.items
            cursor = page.cursor
            hasMore = page.hasMore
            loadFailed = false
        } catch {
            loadFailed = posts.isEmpty
            app?.report(error)
        }
        if let t = await trayTask { tray = t }
        // Feed pages are short (ads and suggestions are left out): fill a few grid rows.
        var tries = 0
        while posts.count < 8, hasMore, tries < 3 {
            tries += 1
            await loadMore()
        }
        #if DEBUG
        // `-IGOpen post|story`: open the first post or a story on launch (for screenshots).
        switch UserDefaults.standard.string(forKey: "IGOpen") {
        case "post": open(at: 0)
        case "story": app?.openStories(tray, at: min(3, max(0, tray.count - 1)))
        default: break
        }
        #endif
    }

    func loadMore() async {
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
        opened = MediaDetailModel(pk: shown[index].pk, media: shown[index], client: client)
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
