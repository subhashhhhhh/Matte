import SwiftUI

/// A grid of posts you can open large and step through: Explore and profiles.
@Observable
final class MediaBrowser {
    private(set) var items: [Media] = []
    /// The tile previewing its video on hover (one at a time).
    var playing: String?
    private(set) var opened: MediaDetailModel?
    private(set) var openedIndex: Int?
    @ObservationIgnored private let client: IGClient
    /// Called when the grid or the opened post gets near the end (load the next page).
    @ObservationIgnored var nearEnd: (() -> Void)?

    init(client: IGClient) { self.client = client }

    func append(_ more: [Media]) {
        let known = Set(items.map(\.pk))
        items += more.filter { !known.contains($0.pk) }
    }

    func reset() {
        items = []
        closeOpened()
    }

    func open(at index: Int) {
        guard items.indices.contains(index) else { return }
        playing = nil
        openedIndex = index
        // Grids like a profile's Reels tab list videos by cover only: fetch the full post.
        let item = items[index]
        let complete = !(item.kind == .video && item.videos.isEmpty)
        opened = MediaDetailModel(pk: item.pk, media: complete ? item : nil, client: client)
        if items.count - index < 4 { nearEnd?() }
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

    func appeared(_ index: Int) {
        if index >= items.count - 6 { nearEnd?() }
    }
}

/// The Explore page: Instagram's picks for you, endlessly.
@Observable
final class ExploreModel {
    let browser: MediaBrowser
    private(set) var isLoading = false
    private(set) var loadFailed = false
    @ObservationIgnored private var maxId: String?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var hasMore = true
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let client: IGClient

    init(app: AppModel, client: IGClient) {
        self.app = app
        self.client = client
        browser = MediaBrowser(client: client)
        browser.nearEnd = { [weak self] in Task { await self?.loadMore() } }
    }

    func loadIfNeeded() async {
        guard browser.items.isEmpty else { return }
        #if DEBUG
        // `-IGOpenMediaPk <pk>`: open that post first (screenshots of a specific post).
        if let pk = UserDefaults.standard.string(forKey: "IGOpenMediaPk"), let m = try? await client.mediaInfo(pk: pk) {
            browser.append([m])
            browser.open(at: 0)
        }
        #endif
        await loadMore()
    }

    func refresh() async {
        maxId = nil
        token = nil
        hasMore = true
        browser.reset()
        await loadMore()
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.explore(maxId: maxId, pagingToken: token)
            browser.append(page.items)
            maxId = page.next
            token = page.token ?? token
            hasMore = page.more && page.next != nil && !page.items.isEmpty
            loadFailed = false
        } catch {
            loadFailed = browser.items.isEmpty
            app?.report(error)
        }
    }
}

/// The search box: results as you type, a fresh search session per focus (as the web app does).
@Observable
final class SearchModel {
    var query = "" {
        didSet { if query != oldValue { schedule() } }
    }
    private(set) var results = SearchResults()
    private(set) var isSearching = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var sessionId = UUID().uuidString.lowercased()
    @ObservationIgnored private let client: IGClient

    init(client: IGClient) { self.client = client }

    var isEmpty: Bool { results.users.isEmpty && results.hashtags.isEmpty }

    private func schedule() {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            results = SearchResults()
            isSearching = false
            return
        }
        isSearching = true
        task = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let found = try? await client.search(q, sessionId: sessionId)
            guard !Task.isCancelled else { return }
            if let found { results = found }
            isSearching = false
        }
    }

    func clear() {
        query = ""
        sessionId = UUID().uuidString.lowercased()
    }
}
