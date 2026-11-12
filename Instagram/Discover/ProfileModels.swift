import SwiftUI

// MARK: - Values

/// One story highlight on a profile (its id, "highlight:…", is a story reel id).
nonisolated struct Highlight: Hashable, Sendable, Identifiable, Codable {
    var id: String
    var title: String
    var cover: URL?
}

/// How you and another account follow each other.
nonisolated struct Friendship: Hashable, Sendable {
    var following = false
    var followedBy = false
    /// Your follow request is waiting (private accounts).
    var requested = false
}

/// A saved-posts collection.
nonisolated struct SavedCollection: Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    var count: Int?
    var cover: URL?
    /// The automatic "All posts" collection.
    var isAll = false
    /// Holds posts (not audio): the only kind shown.
    var isMedia = true
}

/// A page pushed over the current one (Back pops it): a profile or a hashtag.
enum StackPage: Identifiable {
    case profile(ProfileModel)
    case hashtag(HashtagModel)

    var id: String {
        switch self {
        case .profile(let m): "user:" + m.user.id
        case .hashtag(let m): "tag:" + m.name.lowercased()
        }
    }
}

/// Shows a pushed page.
struct StackPageView: View {
    let page: StackPage

    var body: some View {
        switch page {
        case .profile(let model): ProfileView(model: model)
        case .hashtag(let model): HashtagView(model: model)
        }
    }
}

// MARK: - A paged grid

/// A grid of posts loaded a page at a time (a profile tab, saved posts, a hashtag).
@Observable
final class MediaFeed {
    let browser: MediaBrowser
    private(set) var isLoading = false
    /// The first page has arrived (or failed): an empty grid now means "nothing here".
    private(set) var settled = false
    private(set) var failed = false
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var hasMore = true
    /// The grid shows cached posts: page 1 must load before paging on.
    @ObservationIgnored private(set) var stale = false
    /// The first page as it last arrived from Instagram (what gets cached).
    @ObservationIgnored private(set) var firstPage: [Media]?
    @ObservationIgnored private let fetch: (String?) async throws -> Page<Media>
    @ObservationIgnored private let onError: (Error) -> Void
    /// Runs once after the first page arrives (debug launch flags).
    @ObservationIgnored var onFirstPage: (() -> Void)?

    init(client: IGClient, onError: @escaping (Error) -> Void, fetch: @escaping (String?) async throws -> Page<Media>) {
        browser = MediaBrowser(client: client)
        self.fetch = fetch
        self.onError = onError
        browser.nearEnd = { [weak self] in Task { await self?.loadMore() } }
    }

    var isEmpty: Bool { settled && browser.items.isEmpty }

    /// Shows cached posts until page 1 arrives.
    func seed(_ items: [Media]) {
        guard browser.items.isEmpty, !items.isEmpty else { return }
        browser.append(items)
        stale = true
        settled = true
    }

    func loadIfNeeded() async {
        guard !settled || stale else { return }
        await loadMore()
    }

    func loadMore() async {
        guard hasMore || stale, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let wasStale = stale
            let page = try await fetch(wasStale ? nil : cursor)
            let first = !settled || wasStale
            if wasStale { browser.replaceCached(with: page.items) } else { browser.append(page.items) }
            if wasStale || cursor == nil { firstPage = page.items }
            stale = false
            cursor = page.cursor
            hasMore = page.hasMore && page.cursor != nil
            failed = false
            settled = true
            if first { onFirstPage?(); onFirstPage = nil }
        } catch {
            if error is CancellationError { return }
            // Cached posts stay (and `stale` lets a later load try page 1 again).
            if stale { return }
            hasMore = false
            failed = browser.items.isEmpty
            settled = true
            if browser.items.isEmpty { onError(error) }
        }
    }

    func retry() async {
        guard !stale else { return await loadMore() }
        hasMore = true
        settled = false
        failed = false
        await loadMore()
    }
}

// MARK: - Profile

enum ProfileTab: String, CaseIterable, Identifiable {
    case posts, reels, tagged, saved
    var id: String { rawValue }

    var title: String {
        switch self {
        case .posts: "Posts"
        case .reels: "Reels"
        case .tagged: "Tagged"
        case .saved: "Saved"
        }
    }
}

/// One account's page: header, highlights and the Posts / Reels / Tagged (and, on your own
/// page, Saved) grids.
@Observable
final class ProfileModel: Identifiable {
    let user: User
    private(set) var profile: Profile?
    private(set) var highlights: [Highlight] = []
    private(set) var failed = false
    var tab: ProfileTab = .posts {
        didSet { if tab != oldValue { Task { await activeFeed.loadIfNeeded() } } }
    }
    let posts: MediaFeed
    private(set) var reels: MediaFeed
    private(set) var tagged: MediaFeed
    /// Saved posts, for the selected collection (your own page only).
    private(set) var saved: MediaFeed
    private(set) var collections: [SavedCollection] = []
    private(set) var collectionId: String?
    /// The followers or following list, when open.
    var followList: FollowListModel?
    private(set) var followBusy = false
    /// "Following" was clicked once: the button asks to confirm the unfollow.
    var confirmingUnfollow = false

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let client: IGClient
    @ObservationIgnored private var started = false

    var id: String { user.id }
    var isMe: Bool { app?.viewerId == user.id }

    init(user: User, app: AppModel, client: IGClient) {
        self.user = user
        self.app = app
        self.client = client
        let report: (Error) -> Void = { [weak app] in app?.report($0) }
        let username = user.username, id = user.id
        posts = MediaFeed(client: client, onError: report) { try await client.profilePosts(username: username, after: $0) }
        reels = MediaFeed(client: client, onError: report) { try await client.profileReels(userId: id, after: $0) }
        tagged = MediaFeed(client: client, onError: report) { try await client.profileTagged(userId: id, after: $0) }
        saved = MediaFeed(client: client, onError: report) { try await client.savedPosts(maxId: $0) }
    }

    var activeFeed: MediaFeed {
        switch tab {
        case .posts: posts
        case .reels: reels
        case .tagged: tagged
        case .saved: saved
        }
    }

    var tabs: [ProfileTab] { isMe ? ProfileTab.allCases : [.posts, .reels, .tagged] }

    /// Private and not followed: only the header shows.
    var isLocked: Bool { profile?.isPrivate == true && profile?.following != true && !isMe }

    static let cachedProfiles = 20
    private var cacheKey: String { "profile-" + user.id }

    /// What's kept of a profile between visits: the header and the first posts.
    nonisolated struct Snapshot: Codable, Sendable {
        var profile: Profile
        var highlights: [Highlight]
        var posts: [Media]
    }

    func start() async {
        guard !started else { return }
        started = true
        if let cache = app?.cache, let snap = cache.load(Snapshot.self, cacheKey, maxAge: 14 * 86_400)?.value {
            cache.touch(cacheKey)
            profile = snap.profile
            highlights = snap.highlights
            posts.seed(snap.posts.cacheable(12))
        }
        #if DEBUG
        // `-IGProfileTab reels|tagged|saved` and `-IGProfileList followers|following` (screenshots).
        let d = UserDefaults.standard
        if let raw = d.string(forKey: "IGProfileTab"), let t = ProfileTab(rawValue: raw) { tab = t }
        if let list = d.string(forKey: "IGProfileList") { openFollowList(followers: list == "followers") }
        if d.string(forKey: "IGOpen") == "post" {
            // `-IGOpenIndex N`: the Nth post of the tab, or the first collab post with `-IGOpenIndex collab`.
            let feed = activeFeed
            feed.onFirstPage = { [feed] in
                let raw = d.string(forKey: "IGOpenIndex")
                let index = raw == "collab" ? feed.browser.items.firstIndex { !$0.coauthors.isEmpty } : Int(raw ?? "0")
                feed.browser.open(at: index ?? 0)
            }
        }
        #endif
        async let header: Void = loadHeader()
        async let grid: Void = activeFeed.loadIfNeeded()
        async let rings: Void = loadHighlights()
        _ = await (header, grid, rings)
        saveSnapshot()
    }

    @ObservationIgnored private var headerFresh = false
    @ObservationIgnored private var highlightsFresh = false

    /// Keeps the header and first posts for next time (the 20 most recently opened profiles).
    private func saveSnapshot() {
        guard let cache = app?.cache, headerFresh, let profile else { return }
        let first = posts.firstPage ?? (isLocked ? [] : nil)
        guard let first else { return }
        cache.save(Snapshot(profile: profile, highlights: highlightsFresh ? highlights : [], posts: first.cacheable(12)), cacheKey)
        cache.trim(prefix: "profile-", keep: Self.cachedProfiles)
    }

    private func loadHeader() async {
        do {
            profile = try await client.profile(id: user.id)
            headerFresh = true
            failed = false
        } catch {
            failed = profile == nil
            app?.report(error)
        }
        if isMe { await loadCollections() }
    }

    private func loadHighlights() async {
        if let fresh = try? await client.highlights(userId: user.id) {
            highlights = fresh
            highlightsFresh = true
        }
        #if DEBUG
        // `-IGOpenHighlight N`: play the Nth highlight (screenshots).
        let n = UserDefaults.standard.integer(forKey: "IGOpenHighlight")
        if UserDefaults.standard.object(forKey: "IGOpenHighlight") != nil, highlights.indices.contains(n) {
            openHighlight(highlights[n])
        }
        #endif
    }

    private func loadCollections() async {
        let all = (try? await client.savedCollections()) ?? []
        collections = all.filter { $0.isMedia && !$0.isAll }
    }

    /// Shows one saved collection (nil: all saved posts).
    func selectCollection(_ id: String?) {
        guard id != collectionId else { return }
        collectionId = id
        saved.browser.closeOpened()
        let report: (Error) -> Void = { [weak app] in app?.report($0) }
        let client = client
        saved = MediaFeed(client: client, onError: report) { cursor in
            if let id { try await client.collectionPosts(id: id, maxId: cursor) } else { try await client.savedPosts(maxId: cursor) }
        }
        Task { await saved.loadIfNeeded() }
    }

    /// Plays a highlight in the story viewer (the rest of the row follows it).
    func openHighlight(_ highlight: Highlight) {
        guard let app, let index = highlights.firstIndex(of: highlight) else { return }
        let owner = profile?.user ?? user
        let reels = highlights.map { StoryReel(id: $0.id, user: owner, seen: true) }
        app.openStories(reels, at: index)
    }

    func openFollowList(followers: Bool) {
        followList = FollowListModel(owner: profile?.user ?? user, followers: followers, isMine: isMe, client: client, app: app)
    }

    // MARK: Following

    /// Follow, or (after confirming) unfollow / withdraw the request.
    func followTapped() {
        guard let p = profile, !followBusy else { return }
        if p.following || p.requested {
            if !confirmingUnfollow {
                confirmingUnfollow = true
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    confirmingUnfollow = false
                }
                return
            }
            confirmingUnfollow = false
            Task { await setFollowing(false) }
        } else {
            Task { await setFollowing(true) }
        }
    }

    private func setFollowing(_ follow: Bool) async {
        guard var p = profile else { return }
        followBusy = true
        defer { followBusy = false }
        let before = p
        // Optimistic: a public account is followed at once; a private one gets a request.
        p.following = follow && !p.isPrivate
        p.requested = follow && p.isPrivate
        if !before.following, p.following { p.followerCount = p.followerCount.map { $0 + 1 } }
        if before.following, !follow { p.followerCount = p.followerCount.map { max(0, $0 - 1) } }
        profile = p
        do {
            let f = try await client.setFollowing(follow, userId: user.id)
            p.following = f.following
            p.requested = f.requested
            p.followedBy = f.followedBy
            profile = p
        } catch {
            profile = before
            app?.report(error)
        }
    }
}

// MARK: - Followers and following

/// Someone's followers, or the accounts they follow, a page at a time.
@Observable
final class FollowListModel: Identifiable {
    let owner: User
    let followers: Bool
    /// Your own list ("Follows you" is then implied for followers and not shown).
    let isMine: Bool
    private(set) var users: [User] = []
    private(set) var friendships: [String: Friendship] = [:]
    private(set) var isLoading = false
    private(set) var settled = false
    private(set) var failed = false
    /// More pages may follow.
    private(set) var hasMore = true
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private let client: IGClient
    @ObservationIgnored private weak var app: AppModel?

    var id: String { owner.id + (followers ? "/followers" : "/following") }
    var title: String { followers ? "Followers" : "Following" }

    init(owner: User, followers: Bool, isMine: Bool, client: IGClient, app: AppModel?) {
        self.owner = owner
        self.followers = followers
        self.isMine = isMine
        self.client = client
        self.app = app
    }

    func followsYou(_ user: User) -> Bool {
        guard !(isMine && followers) else { return false }
        return friendships[user.id]?.followedBy == true
    }

    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.followList(userId: owner.id, followers: followers, maxId: cursor)
            let known = Set(users.map(\.id))
            let fresh = page.items.filter { !known.contains($0.id) }
            users += fresh
            cursor = page.cursor
            hasMore = page.hasMore
            settled = true
            failed = false
            let ids = fresh.map(\.id).filter { $0 != app?.viewerId }
            // "Follows you" marks are extra: a failure here never reports (or signs out).
            if !(isMine && followers), !ids.isEmpty, let found = try? await client.friendships(ids) {
                friendships.merge(found) { $1 }
            }
        } catch {
            if error is CancellationError { return }
            hasMore = false
            settled = true
            failed = users.isEmpty
            if users.isEmpty { app?.report(error) }
        }
    }

    func appeared(_ user: User) {
        if let i = users.lastIndex(of: user), i >= users.count - 4 { Task { await loadMore() } }
    }
}

// MARK: - Hashtag

/// A hashtag's page: its post count and top posts.
@Observable
final class HashtagModel: Identifiable {
    let name: String
    private(set) var info: Hashtag?
    let feed: MediaFeed
    @ObservationIgnored private let client: IGClient
    @ObservationIgnored private let sessionId: String
    @ObservationIgnored private var started = false

    var id: String { name }

    init(name: String, app: AppModel, client: IGClient) {
        let tag = name.hasPrefix("#") ? String(name.dropFirst()) : name
        self.name = tag
        self.client = client
        let session = UUID().uuidString.lowercased()
        sessionId = session
        feed = MediaFeed(client: client, onError: { [weak app] in app?.report($0) }) {
            try await client.hashtagPosts(tag, sessionId: session, after: $0)
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        async let grid: Void = feed.loadIfNeeded()
        async let header: Hashtag? = try? client.hashtagInfo(name, sessionId: sessionId)
        info = await header ?? nil
        _ = await grid
    }
}
