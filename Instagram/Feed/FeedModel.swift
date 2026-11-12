import SwiftUI

/// The home feed and the stories tray above it.
@Observable
final class FeedModel {
    private(set) var posts: [Media] = []
    private(set) var tray: [StoryReel] = []
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private var cursor: String?
    private var hasMore = true
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
            let page = try await client.homeFeed()
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
    }

    func loadMore() async {
        guard hasMore, let cursor, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.homeFeed(after: cursor)
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
        guard posts.indices.contains(index) else { return }
        playing = nil
        openedIndex = index
        opened = MediaDetailModel(pk: posts[index].pk, media: posts[index], client: client)
        if posts.count - index < 4 { Task { await loadMore() } }
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
