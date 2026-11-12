import SwiftUI
import OSLog

enum Destination: String, CaseIterable, Identifiable {
    case home, explore, reels, messages
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .explore: "Explore"
        case .reels: "Reels"
        case .messages: "Messages"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .explore: "safari"
        case .reels: "play.rectangle.on.rectangle"
        case .messages: "paperplane"
        }
    }

    var glyph: (outline: IGIcon, filled: IGIcon) {
        switch self {
        case .home: (.home, .homeFilled)
        case .explore: (.explore, .exploreFilled)
        case .reels: (.reels, .reelsFilled)
        case .messages: (.direct, .directFilled)
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .home: "1"
        case .explore: "2"
        case .reels: "3"
        case .messages: "4"
        }
    }
}

/// Central state: the session, the API client, navigation and the page models (kept alive
/// while you switch between them, so each keeps its place).
@Observable
final class AppModel {
    enum AuthState: Equatable { case signedOut, signedIn }

    private(set) var authState: AuthState = .signedOut
    private(set) var client: IGClient?
    var showSignIn = false
    var destination: Destination = .messages {
        didSet {
            visited.insert(destination)
            profiles = []
        }
    }
    /// Profiles opened on top of the current page, newest last (Back pops one).
    private(set) var profiles: [ProfileModel] = []
    /// The signed-in account (filled in after sign-in).
    private(set) var me: User?
    private(set) var viewerId: String?
    /// Pages opened at least once: only these are built (a page never visited loads nothing).
    private(set) var visited: Set<Destination> = [.messages]
    /// The story viewer, when open.
    var stories: StoryViewerModel?
    /// A post opened from a DM or elsewhere, shown over the current page.
    var openedMedia: Media?
    /// Shown as a small banner (errors, "copied").
    var toast: String?
    /// The ⌘K quick switcher.
    var showSwitcher = false
    /// The post being sent to chats (the "Send to…" sheet), when open.
    var sharing: Media?
    /// Like/save/send/copy/download for posts and reels everywhere.
    private(set) var actions: PostActions?

    private(set) var feed: FeedModel?
    private(set) var reels: ReelsModel?
    private(set) var inbox: InboxModel?
    private(set) var explore: ExploreModel?
    private(set) var search: SearchModel?
    private(set) var activity: ActivityModel?

    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Instagram", category: "App")

    init() {
        if let session = IGSession.restore() { start(IGClient(session: session)) }
        #if DEBUG
        // `-IGStartPage home|reels|messages`: open on that page (for screenshots).
        if let raw = UserDefaults.standard.string(forKey: "IGStartPage"), let d = Destination(rawValue: raw) {
            destination = d
        }
        // `-IGShowSwitcher YES`: open the ⌘K switcher at launch.
        showSwitcher = UserDefaults.standard.bool(forKey: "IGShowSwitcher")
        #endif
    }

    private func start(_ client: IGClient) {
        self.client = client
        authState = .signedIn
        feed = FeedModel(app: self, client: client)
        reels = ReelsModel(app: self, client: client)
        inbox = InboxModel(app: self, client: client)
        actions = PostActions(app: self, client: client)
        explore = ExploreModel(app: self, client: client)
        search = SearchModel(client: client)
        let activity = ActivityModel(app: self, client: client)
        self.activity = activity
        #if DEBUG
        // `-IGOpenActivity YES`: open the notifications panel (never marks them seen).
        if UserDefaults.standard.bool(forKey: "IGOpenActivity") {
            ActivityModel.debugNeverMarkSeen = true
            activity.isOpen = true
        }
        #endif
        // The heart's dot: check now and every few minutes.
        Task { [weak activity] in
            while let activity, !Task.isCancelled {
                await activity.refresh()
                try? await Task.sleep(for: .seconds(300))
            }
        }
        Task {
            guard let id = await client.session.userId else { return }
            viewerId = id
            me = try? await client.profile(id: id).user
            #if DEBUG
            // `-IGOpenProfileFor <query>`: search and open the first person found (screenshots).
            if let q = UserDefaults.standard.string(forKey: "IGOpenProfileFor"),
               let user = try? await client.search(q, sessionId: UUID().uuidString.lowercased()).users.first {
                openProfile(user)
            }
            #endif
        }
    }

    // MARK: Navigation

    func openProfile(_ user: User) {
        guard let client else { return }
        activity?.isOpen = false
        activity?.opened = nil
        stories?.close()
        if profiles.last?.user.id == user.id { return }
        profiles.append(ProfileModel(user: user, app: self, client: client))
    }

    func closeProfile() {
        guard !profiles.isEmpty else { return }
        profiles.removeLast()
        MemoryRelief.soon()
    }

    func openChat(_ threadId: String) {
        destination = .messages
        inbox?.selectedId = threadId
    }

    func completeSignIn(_ cookies: [StoredCookie]) {
        SessionStore.shared.save(cookies)
        start(IGClient(session: IGSession(cookies: cookies)))
        showSignIn = false
        log.info("Signed in")
    }

    func signOut() {
        let old = client
        Task { await old?.session.end() }
        SessionStore.shared.clear()
        inbox?.stop()
        client = nil
        feed = nil
        reels = nil
        inbox = nil
        explore = nil
        search = nil
        activity = nil
        profiles = []
        me = nil
        viewerId = nil
        actions = nil
        sharing = nil
        stories = nil
        authState = .signedOut
    }

    /// Handles an error from any page: a dead session signs out, the rest become a toast.
    func report(_ error: Error) {
        if case IGError.signedOut = error {
            signOut()
            showSignIn = true
            return
        }
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        show(error.localizedDescription)
    }

    func show(_ message: String) {
        toast = message
        let shown = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if toast == shown { toast = nil }
        }
    }

    func openStories(_ tray: [StoryReel], at index: Int) {
        guard let client, tray.indices.contains(index) else { return }
        stories = StoryViewerModel(app: self, client: client, reels: tray, start: index)
    }
}
