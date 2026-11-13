import SwiftUI
import OSLog

enum Destination: String, CaseIterable, Identifiable {
    case home, explore, reels, messages
    /// Manager mode only: the calendar of scheduled posts.
    case planner
    /// Manager mode only: comments on your recent posts that wait for an answer.
    case replies
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .explore: "Explore"
        case .reels: "Reels"
        case .messages: "Messages"
        case .planner: "Planner"
        case .replies: "Replies"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .explore: "safari"
        case .reels: "play.rectangle.on.rectangle"
        case .messages: "paperplane"
        case .planner: "calendar"
        case .replies: "bubble.left.and.text.bubble.right"
        }
    }

    var glyph: (outline: IGIcon, filled: IGIcon) {
        switch self {
        case .home: (.home, .homeFilled)
        case .explore: (.explore, .exploreFilled)
        case .reels: (.reels, .reelsFilled)
        case .messages: (.direct, .directFilled)
        case .planner: (.calendar, .calendarFilled)
        case .replies: (.comment, .commentFilled)
        }
    }

    var managerOnly: Bool { self == .planner || self == .replies }

    var shortcut: KeyEquivalent {
        switch self {
        case .home: "1"
        case .explore: "2"
        case .reels: "3"
        case .messages: "4"
        case .planner: "5"
        case .replies: "6"
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
    /// Opens where you left it (Home the first time).
    var destination: Destination = Destination(rawValue: UserDefaults.standard.string(forKey: "lastPage") ?? "") ?? .home {
        didSet {
            // Leaving with a post or reel open (another tab, or the same tab closing a profile):
            // it shrinks into the mini player, as opening a profile does.
            if !restoringMini, destination != oldValue || !profiles.isEmpty {
                shrinkOpenPost(from: .init(destination: oldValue, profiles: profiles))
            }
            visited.insert(destination)
            profiles = []
            UserDefaults.standard.set(destination.rawValue, forKey: "lastPage")
        }
    }
    /// Profiles and hashtags opened on top of the current page, newest last (Back pops one).
    private(set) var profiles: [StackPage] = []
    /// The signed-in account (filled in after sign-in).
    private(set) var me: User?
    private(set) var viewerId: String?
    /// Pages opened at least once: only these are built (a page never visited loads nothing).
    private(set) var visited: Set<Destination> = [Destination(rawValue: UserDefaults.standard.string(forKey: "lastPage") ?? "") ?? .home]
    /// The story viewer, when open.
    var stories: StoryViewerModel?
    /// A post opened from a DM or elsewhere, shown over the current page.
    var openedMedia: Media?
    /// A post opened from somewhere without a grid (a story's post sticker): shown over everything.
    var openedPost: MediaDetailModel?

    /// The post or reel open in a viewer right now, where it sits (in the page area), and how to
    /// close that viewer: going to a profile shrinks it into the mini player instead.
    struct PresentedPost {
        let model: MediaDetailModel
        var frame: CGRect
        let close: () -> Void
    }
    var presentedPost: PresentedPost?

    /// A post or reel kept playing small in the corner after you left it (a profile, another tab).
    struct MiniPost: Identifiable {
        let id = UUID()
        let model: MediaDetailModel
        /// Where it was when it shrank (it flies from there, and back).
        let from: CGRect
        /// Where you were: going back returns there.
        let origin: Origin

        struct Origin {
            var destination: Destination
            var profiles: [StackPage]
            /// The Reels page itself (going back plays it there, not in a viewer).
            var isReelsPage: Bool { destination == .reels && profiles.isEmpty }
        }
    }
    var miniPost: MiniPost?
    @ObservationIgnored private var restoringMini = false

    /// The open post or reel shrinks into the mini player (you're leaving `origin`).
    private func shrinkOpenPost(from origin: MiniPost.Origin) {
        guard let p = presentedPost, p.model.media != nil else { return }
        VideoHandoff.shared.expect()
        if origin.isReelsPage { reels?.handOffCurrent() }
        presentedPost = nil
        miniPost = MiniPost(model: p.model, from: p.frame, origin: origin)
        p.close()
        #if DEBUG
        FileHandle.standardError.write(Data("MINI shrink from \(origin.destination) +\(origin.profiles.count) profiles\n".utf8))
        #endif
    }

    /// Back to where the mini player's post was: that page (and the profiles you had open), the
    /// post open there again, still playing (a reel from the Reels page plays on in Reels).
    func returnFromMini() {
        beginReturnFromMini()
        finishReturnFromMini()
    }

    /// Step 1: the page you were on comes back behind the mini player (it then grows into place).
    func beginReturnFromMini() {
        guard let mini = miniPost else { return }
        VideoHandoff.shared.expect()
        restoringMini = true
        activity?.isOpen = false
        destination = mini.origin.destination
        profiles = mini.origin.profiles
        restoringMini = false
    }

    /// Step 2: it's in place: the post's viewer takes over (a reel plays on in Reels).
    func finishReturnFromMini() {
        guard let mini = miniPost else { return }
        VideoHandoff.shared.expect()
        miniPost = nil
        if !mini.origin.isReelsPage {
            openedPostFromMini = true
            openedPost = mini.model
        }
        #if DEBUG
        FileHandle.standardError.write(Data("MINI back to \(destination) +\(profiles.count) profiles, post open: \(openedPost != nil)\n".utf8))
        #endif
    }

    /// The opened post grew out of the mini player: it appears at once (no fade), already in place.
    var openedPostFromMini = false
    /// Shown as a small banner (errors, "copied").
    var toast: String?
    /// The ⌘K quick switcher.
    var showSwitcher = false
    /// The post being sent to chats (the "Send to…" sheet), when open.
    var sharing: Media?
    /// Like/save/send/copy/download for posts and reels everywhere.
    private(set) var actions: PostActions?
    /// The create sheet, when open.
    private(set) var creating: CreateModel?
    /// The story editor, when open.
    private(set) var storyEditor: StoryEditorModel?
    /// Posts, reels and stories sharing in the background (the corner rings).
    var uploads: [UploadJob] = []
    /// The sidebar "+" menu (Post, Reel, Story).
    var showCreateMenu = false
    /// Files dropped on the window that could be a reel or a story: asks which.
    var droppedFiles: [URL]?
    /// Your post whose caption is being edited.
    var editingCaption: Media?
    /// Your post waiting for "Delete?" to be confirmed.
    var confirmingDelete: Media?

    private(set) var planner: PlannerModel?
    private(set) var replies: RepliesModel?
    private(set) var feed: FeedModel?
    private(set) var reels: ReelsModel?
    private(set) var inbox: InboxModel?
    private(set) var explore: ExploreModel?
    private(set) var search: SearchModel?
    private(set) var activity: ActivityModel?
    /// Every account signed in on this Mac, the current one included, in the switcher's order.
    private(set) var accounts: [AccountSummary] = []
    /// Parking one account and starting another (the switcher waits).
    private(set) var switchingAccount = false
    /// The manager tools (planner, scheduling, replies, insights): on for a professional (business
    /// or creator) account, which is what Instagram's scheduling needs; off for a personal one.
    /// Read from the account's profile (remembered in `accounts.json` for the next launch).
    private(set) var managerMode = false {
        didSet { if !managerMode, destination.managerOnly { destination = .home } }
    }
    /// The pages the sidebar shows (a professional account adds the Planner and Replies).
    var destinations: [Destination] { Destination.allCases.filter { managerMode || !$0.managerOnly } }
    /// The sidebar is a narrow rail of icons (⌘S), remembered across launches.
    var isSidebarCollapsed = UserDefaults.standard.bool(forKey: "sidebarCollapsed") {
        didSet { UserDefaults.standard.set(isSidebarCollapsed, forKey: "sidebarCollapsed") }
    }
    /// Where the sidebar's Create item is (window coordinates): the create menu opens beside it.
    @ObservationIgnored var createItemFrame: CGRect = .zero
    /// The sidebar column's width now (the panel and its inset).
    var sidebarWidth: CGFloat { isSidebarCollapsed ? SidebarMetrics.railWidth : SidebarMetrics.fullWidth }

    func toggleSidebar() {
        withAnimation(.smooth(duration: 0.3)) { isSidebarCollapsed.toggle() }
    }
    /// The Settings page, when open.
    var showSettings = false
    /// Bumped each time a session starts (sign-in, switch): the pages take it as their identity,
    /// so views built for the last account (and their one-time loads) start over.
    private(set) var generation = 0
    /// The current account's id (`ds_user_id`).
    var accountId: String? { client?.session.accountId }

    /// Last good results on disk, for this account (nil when signed out).
    @ObservationIgnored private(set) var cache: ResponseCache?

    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Instagram", category: "App")

    init() {
        // Manager mode used to be a switch in Settings; it now follows the account type.
        UserDefaults.standard.removeObject(forKey: "managerMode")
        if let session = IGSession.restore() {
            if let id = session.accountId {
                // Left parked by a switch that didn't finish: the current copy wins.
                AccountStore.shared.dropParked(id)
                accounts = AccountStore.shared.upsert(AccountSummary(id: id))
            }
            start(IGClient(session: session))
        } else {
            startNextParkedAccount()
        }
        #if DEBUG
        // `-IGStartPage home|reels|messages`: open on that page (for screenshots).
        if let raw = UserDefaults.standard.string(forKey: "IGStartPage"), let d = Destination(rawValue: raw) {
            destination = d
        }
        // `-IGAddToStory YES`: "Add to story" for the first photo post in the feed (share only with a dry run).
        if let addMode = UserDefaults.standard.string(forKey: "IGAddToStory") {
            Task {
                for _ in 0..<60 {
                    try? await Task.sleep(for: .milliseconds(500))
                    // `-IGAddToStory reel`: the first reel instead; `-IGAddToStory <pk>`: that post.
                    let wantReel = addMode == "reel"
                    var chosen = feed?.posts.first(where: { wantReel ? $0.productType == "clips" : !$0.isVideo })
                    if addMode.allSatisfy(\.isNumber), let client { chosen = try? await client.mediaInfo(pk: addMode) }
                    if let post = chosen {
                        addToStory(post)
                        // `-IGReshareLook photo` / `-IGStoryMode background`: set up the editor for screenshots.
                        let d = UserDefaults.standard
                        if d.string(forKey: "IGReshareLook") == "photo" || d.string(forKey: "IGStoryMode") == "background" {
                            while storyEditor?.reshare == nil { try? await Task.sleep(for: .milliseconds(200)) }
                            if d.string(forKey: "IGReshareLook") == "photo" { storyEditor?.toggleCardStyle() }
                            if d.string(forKey: "IGStoryMode") == "background" { storyEditor?.setMode(.background) }
                        }
                        // `-IGStoryShare YES` with `-IGDryRunWrites`: presses Share once the card is in.
                        if UserDefaults.standard.bool(forKey: "IGStoryShare"), UserDefaults.standard.string(forKey: "IGDryRunWrites") != nil {
                            while storyEditor?.reshare == nil { try? await Task.sleep(for: .milliseconds(200)) }
                            storyEditor?.share()
                        }
                        break
                    }
                }
            }
        }
        // `-IGSwitchTo messages`: go to that page 12 s after launch and back 6 s later (playback tests).
        if let raw = UserDefaults.standard.string(forKey: "IGSwitchTo"), let to = Destination(rawValue: raw) {
            Task {
                try? await Task.sleep(for: .seconds(12))
                let from = destination
                FileHandle.standardError.write(Data("SWITCH to \(raw)\n".utf8))
                destination = to
                try? await Task.sleep(for: .seconds(6))
                // `-IGMiniBack YES`: go back through the mini player instead of the tab.
                if UserDefaults.standard.bool(forKey: "IGMiniBack"), miniPost != nil {
                    returnFromMini()
                    return
                }
                FileHandle.standardError.write(Data("SWITCH back\n".utf8))
                destination = from
            }
        }
        // `-IGMiniTest YES`: 10 s after launch, open the open post's author (the mini player).
        if UserDefaults.standard.bool(forKey: "IGMiniTest") {
            Task {
                try? await Task.sleep(for: .seconds(10))
                if let user = presentedPost?.model.media?.user {
                    FileHandle.standardError.write(Data("MINI open profile\n".utf8))
                    openProfile(user)
                    // `-IGMiniExpand YES`: open it full size again 5 s later.
                    if UserDefaults.standard.bool(forKey: "IGMiniExpand") {
                        try? await Task.sleep(for: .seconds(5))
                        FileHandle.standardError.write(Data("MINI expand\n".utf8))
                        returnFromMini()
                        // `-IGMiniShare YES`: then press Send on it (the share sheet must show on top).
                        if UserDefaults.standard.bool(forKey: "IGMiniShare") {
                            try? await Task.sleep(for: .seconds(2))
                            sharing = openedPost?.media
                        }
                    }
                }
            }
        }
        // `-IGLogScroll YES`: log every scroll event with the views under the pointer, to
        // ~/Library/Logs/Matte-scroll.log (finding what swallows scrolling).
        if UserDefaults.standard.bool(forKey: "IGLogScroll") {
            let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/Matte-scroll.log")
            try? Data().write(to: url)
            let handle = try? FileHandle(forWritingTo: url)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
                guard let window = e.window, let content = window.contentView else { return e }
                let p = content.convert(e.locationInWindow, from: nil)
                var chain: [String] = []
                var v = content.hitTest(p)
                while let view = v, chain.count < 14 { chain.append(String(describing: type(of: view))); v = view.superview }
                let line = String(format: "%.3f dy=%.1f phase=%lu momentum=%lu full=%d win=%.0fx%.0f at=%.0f,%.0f | ",
                                  e.timestamp, e.scrollingDeltaY, e.phase.rawValue, e.momentumPhase.rawValue,
                                  window.styleMask.contains(.fullScreen) ? 1 : 0, window.frame.width, window.frame.height, p.x, p.y)
                    + chain.joined(separator: " < ") + "\n"
                handle?.seekToEndOfFile()
                handle?.write(Data(line.utf8))
                return e
            }
            }
        }
        // `-IGFullScreen YES`: put the window in full screen 1 s after launch.
        if UserDefaults.standard.bool(forKey: "IGFullScreen") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.toggleFullScreen(nil)
            }
        }
        // `-IGShowSwitcher YES`: open the ⌘K switcher at launch.
        showSwitcher = UserDefaults.standard.bool(forKey: "IGShowSwitcher")
        // `-IGOpenSettings YES`: open Settings at launch.
        showSettings = UserDefaults.standard.bool(forKey: "IGOpenSettings")
        // `-IGSwitchAccount YES`: switch to the next signed-in account 5 s after launch.
        if UserDefaults.standard.bool(forKey: "IGSwitchAccount") {
            Task {
                try? await Task.sleep(for: .seconds(5))
                if let next = accounts.first(where: { $0.id != accountId }) { switchAccount(to: next.id) }
            }
        }
        #endif
    }

    /// Shows or hides the manager tools. Debug builds: `-IGForceManager YES` shows them for a
    /// personal account too (screenshots, dry runs).
    private func setManagerMode(_ professional: Bool) {
        var on = professional
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "IGForceManager") { on = true }
        #endif
        if managerMode != on { managerMode = on }
    }

    private func start(_ client: IGClient) {
        self.client = client
        generation += 1
        cache = ResponseCache(account: client.session.accountId)
        authState = .signedIn
        // What the account was last time, until its profile says.
        setManagerMode(accounts.first { $0.id == client.session.accountId }?.professional ?? false)
        if destination.managerOnly, !managerMode { destination = .home }
        feed = FeedModel(app: self, client: client)
        planner = PlannerModel(app: self, client: client)
        replies = RepliesModel(app: self, client: client)
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
            guard self.client === client else { return }
            viewerId = id
            let profile = try? await client.profile(id: id)
            // Switched again while this loaded: it belongs to the other account.
            guard self.client === client else { return }
            let loaded = profile?.user
            me = loaded
            if let profile, let professional = profile.isProfessional { setManagerMode(professional) }
            if let loaded, AccountStore.isValid(loaded.id) {
                accounts = AccountStore.shared.upsert(AccountSummary(loaded, professional: profile?.isProfessional))
            }
            #if DEBUG
            // `-IGOpenMyStory YES`: open your own story (to check the viewer list).
            // `-IGOpenArchive YES` / `-IGOpenMe YES`: open your archive / your profile.
            if UserDefaults.standard.bool(forKey: "IGOpenArchive") { openArchive() }
            if UserDefaults.standard.bool(forKey: "IGOpenMe"), let me { openProfile(me) }
            if UserDefaults.standard.bool(forKey: "IGOpenMyStory"), let me {
                openStories([StoryReel(id: me.id, user: me, seen: true)], at: 0)
            }
            DebugCreate.openIfAsked(self)
            // `-IGCreateScheduleDays N` (with `-IGCreateFiles`): the sheet set to publish in N days.
            let days = UserDefaults.standard.double(forKey: "IGCreateScheduleDays")
            if days > 0 { creating?.scheduleAt = SchedulePicker.clamp(.now.addingTimeInterval(days * 86_400)) }
            DebugStoryEditor.openIfAsked(self)
            #endif
            #if DEBUG
            // `-IGOpenProfileFor <query>`: search and open the first person found (screenshots).
            if let q = UserDefaults.standard.string(forKey: "IGOpenProfileFor"),
               let user = try? await client.search(q, sessionId: UUID().uuidString.lowercased()).users.first {
                openProfile(user)
            }
            if let tag = UserDefaults.standard.string(forKey: "IGOpenHashtag") { openHashtag(tag) }
            #endif
        }
    }

    // MARK: Navigation

    func openProfile(_ user: User) {
        guard let client else { return }
        // Picked from a likes list: the list's done.
        peopleList = nil
        // The open post or reel shrinks into the corner and keeps playing.
        shrinkOpenPost(from: .init(destination: destination, profiles: profiles))
        activity?.isOpen = false
        activity?.opened = nil
        stories?.close()
        if profiles.last?.id == "user:" + user.id { return }
        profiles.append(.profile(ProfileModel(user: user, app: self, client: client)))
    }

    /// Opens a post by its pk over whatever is showing (the story waits underneath).
    func openPost(pk: String) {
        guard let client else { return }
        openedPost = MediaDetailModel.cached(pk: pk, client: client)
    }

    /// Who liked a post or comment, in the followers-list panel over everything.
    var peopleList: FollowListModel?

    func showLikers(_ media: Media) {
        guard let client else { return }
        let pk = media.pk
        peopleList = FollowListModel(title: "Likes", client: client, app: self) { _ in
            Page(items: try await client.likers(pk: pk), cursor: nil, hasMore: false)
        }
    }

    func showCommentLikers(_ commentId: String) {
        guard let client else { return }
        peopleList = FollowListModel(title: "Likes", client: client, app: self) { cursor in
            try await client.commentLikers(commentId: commentId, after: cursor)
        }
    }

    /// A profile from just a username (a story mention): looked up by search, exact match only.
    func openProfile(username: String) {
        guard let client else { return }
        Task {
            let results = try? await client.search(username, sessionId: UUID().uuidString.lowercased())
            if let user = results?.users.first(where: { $0.username.lowercased() == username.lowercased() }) {
                openProfile(user)
            } else if let url = URL(string: "https://www.instagram.com/\(username)/") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// A hashtag's page ("travel" or "#travel").
    func openHashtag(_ name: String) {
        peopleList = nil
        guard let client else { return }
        stories?.close()
        let page = StackPage.hashtag(HashtagModel(name: name, app: self, client: client))
        if profiles.last?.id == page.id { return }
        profiles.append(page)
    }

    /// Your story archive, on top of the current page.
    func openArchive() {
        guard let client, profiles.last?.id != "archive" else { return }
        profiles.append(.archive(ArchiveModel(app: self, client: client)))
    }

    func closeProfile() {
        guard !profiles.isEmpty else { return }
        shrinkOpenPost(from: .init(destination: destination, profiles: profiles))
        profiles.removeLast()
        MemoryRelief.soon()
    }

    // MARK: Creating

    /// Opens the create sheet (with files dropped on the window or picked, if any). Files
    /// dropped while it's open are added to it.
    func openCreate(_ urls: [URL] = [], target: CreateModel.Target? = nil) {
        guard let client, storyEditor == nil else { return }
        stories?.close()
        showCreateMenu = false
        let model = creating ?? CreateModel(app: self, client: client)
        if creating == nil, let target, target != .story { model.target = target }
        creating = model
        let media = urls.filter(CreateMedia.isMedia)
        if !media.isEmpty { Task { await model.add(media) } }
    }

    func closeCreate() {
        creating?.cancel()
        creating = nil
        MemoryRelief.soon()
    }

    /// Opens the story editor, with a photo or video if one was dropped or picked.
    func openStoryEditor(_ url: URL? = nil) {
        guard let client else { return }
        stories?.close()
        showCreateMenu = false
        if creating?.isSharing != true { creating = nil }
        let model = storyEditor ?? StoryEditorModel(app: self, client: client)
        storyEditor = model
        if let url { Task { await model.load(url) } }
    }

    /// "Add to story" for a post or reel: the story editor with the post as a card.
    func addToStory(_ media: Media) {
        guard let client, storyEditor == nil else { return }
        sharing = nil
        stories?.close()
        if creating?.isSharing != true { creating = nil }
        let model = StoryEditorModel(app: self, client: client)
        storyEditor = model
        Task { await model.loadReshare(media) }
    }

    func closeStoryEditor() {
        storyEditor?.tearDown()
        storyEditor = nil
        MemoryRelief.soon()
    }

    /// Files dropped on the window: photos make a post; a single video asks reel or story.
    func dropped(_ urls: [URL]) {
        let media = urls.filter(CreateMedia.isMedia)
        guard !media.isEmpty, storyEditor == nil else { return }
        if creating != nil { openCreate(media); return }
        let videos = media.filter { !CreateMedia.isPhoto($0) }
        if videos.isEmpty { openCreate(media, target: .post); return }
        if media.count == 1 { droppedFiles = media; return }
        // Several files with a video among them: the sheet takes what it can and says why.
        openCreate(media)
    }

    /// A post, reel or story of yours went up: your profile (and stories) show it next time,
    /// and an open profile of yours reloads now.
    func created(_ media: Media?, story: Bool) {
        refreshMyProfile()
        if story { Task { await feed?.refreshTray(mine: true) } }
    }

    /// One of your posts was deleted: it leaves your open profile's grids and the viewer.
    func removedPost(_ pk: String) {
        for case .profile(let model) in profiles { model.remove(pk: pk) }
        if openedMedia?.pk == pk { openedMedia = nil }
        if let me = viewerId { cache?.remove("profile-" + me) }
    }

    private func refreshMyProfile() {
        guard let me = viewerId else { return }
        cache?.remove("profile-" + me)
        for case .profile(let model) in profiles where model.user.id == me { Task { await model.reloadAfterChange() } }
    }

    func openChat(_ threadId: String) {
        destination = .messages
        inbox?.selectedId = threadId
    }

    // MARK: Accounts

    /// A sign-in finished. With an account already open, that one is parked (kept signed in)
    /// and the new one becomes current; signing in again to the current account replaces it.
    func completeSignIn(_ cookies: [StoredCookie]) {
        showSignIn = false
        let newId = cookies.first { $0.name == "ds_user_id" && !$0.isExpired }?.value
        if let client, let current = accountId, newId != current {
            switchingAccount = true
            Task {
                AccountStore.shared.park(await client.session.endAndTakeCookies(), for: current)
                tearDown()
                becomeCurrent(cookies)
                switchingAccount = false
                log.info("Added an account")
            }
            return
        }
        if let old = client {
            Task { await old.session.end() }
            tearDown()
        }
        becomeCurrent(cookies)
        log.info("Signed in")
    }

    /// Makes `cookies` the current session and starts it.
    private func becomeCurrent(_ cookies: [StoredCookie]) {
        SessionStore.shared.save(cookies)
        if let id = cookies.first(where: { $0.name == "ds_user_id" && !$0.isExpired })?.value, AccountStore.isValid(id) {
            AccountStore.shared.dropParked(id)
            accounts = AccountStore.shared.upsert(AccountSummary(id: id))
        }
        start(IGClient(session: IGSession(cookies: cookies)))
    }

    /// Switches to another signed-in account: the current one is parked (still signed in),
    /// every page starts over for the other one.
    func switchAccount(to id: String) {
        guard id != accountId, !switchingAccount else { return }
        if isPublishing { show("Wait until your post is shared, then switch."); return }
        guard let cookies = AccountStore.shared.unpark(id) else {
            // Its session has ended (expired, or signed out elsewhere).
            let name = accounts.first { $0.id == id }?.handle ?? "That account"
            removeAccount(id)
            show("\(name) is signed out. Add it again to switch to it.")
            return
        }
        switchingAccount = true
        let old = client
        Task {
            if let old, let current = old.session.accountId {
                AccountStore.shared.park(await old.session.endAndTakeCookies(), for: current)
            }
            tearDown()
            becomeCurrent(cookies)
            switchingAccount = false
            MemoryRelief.soon()
            log.info("Switched account")
        }
    }

    /// Opens the sign-in sheet for one more account (the current one stays signed in).
    func addAccount() {
        if isPublishing { show("Wait until your post is shared, then add an account."); return }
        showSettings = false
        showSignIn = true
    }

    /// A post or story is uploading: switching would cancel it.
    var isPublishing: Bool {
        creating?.isSharing == true || storyEditor?.sharer?.isSharing == true || uploads.contains { $0.state == .working }
    }

    /// A failed background post, back in the sheet to change something.
    func reopenCreate(_ model: CreateModel) {
        guard creating == nil, storyEditor == nil else { return }
        creating = model
    }

    /// Share pressed in the create sheet: the sheet closes and the post shares in the corner.
    func shareInBackground() {
        guard let model = creating, let client, model.canShare else { return }
        creating = nil
        uploads.append(UploadJob(sheet: model, app: self, client: client))
    }

    /// Share pressed in the story editor: the editor closes, the story exports and uploads in the corner.
    func shareStoryInBackground(source: CreateSource, doc: StoryDoc, gradient: StoryExport.Gradient, reshare: StoryReshare? = nil) {
        guard let client else { return }
        uploads.append(UploadJob(story: source, doc: doc, gradient: gradient, reshare: reshare, app: self, client: client))
        closeStoryEditor()
    }

    /// Signs out of an account that isn't the current one.
    func removeAccount(_ id: String) {
        guard id != accountId else { signOut(); return }
        accounts = AccountStore.shared.remove(id)
        ResponseCache.clear(account: id)
    }

    /// Signs out of the current account. Another signed-in account, if any, becomes current.
    func signOut() {
        let old = client
        let id = old?.session.accountId
        Task { await old?.session.end() }
        SessionStore.shared.clear()
        cache?.end()
        cache = nil
        if let id { accounts = AccountStore.shared.remove(id) }
        if accounts.isEmpty {
            ResponseCache.clearAll()
        } else if let id {
            ResponseCache.clear(account: id)
        }
        // Nothing of this account may show for the next one: opened posts, cached images (DM photos too).
        MediaDetailModel.clearCache()
        Task { await ImagePipeline.shared.clearAll() }
        tearDown()
        authState = .signedOut
        startNextParkedAccount()
    }

    /// No current session: the first other account still signed in takes over.
    private func startNextParkedAccount() {
        var list = AccountStore.shared.list()
        while let next = list.first {
            if let cookies = AccountStore.shared.unpark(next.id) {
                accounts = list
                becomeCurrent(cookies)
                return
            }
            list = AccountStore.shared.remove(next.id)
        }
        accounts = list
    }

    /// Lets go of every page and model of the current account (not its saved data).
    private func tearDown() {
        inbox?.stop()
        client = nil
        planner = nil
        replies = nil
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
        openedMedia = nil
        creating?.cancel()
        creating = nil
        for job in uploads { job.cancelQuietly() }
        uploads = []
        storyEditor?.tearDown()
        storyEditor = nil
        showCreateMenu = false
        droppedFiles = nil
        editingCaption = nil
        confirmingDelete = nil
        stories = nil
        cache?.end()
        cache = nil
        // Pages are built again on first visit (only the open one now).
        visited = [destination]
    }

    /// Handles an error from any page: a dead session signs out, the rest become a toast.
    func report(_ error: Error) {
        if case IGError.signedOut = error {
            let who = me.map { "@" + $0.username } ?? "This account"
            signOut()
            if authState == .signedIn {
                show("\(who) was signed out by Instagram. Add it again from Settings.")
            } else {
                showSignIn = true
            }
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
