import SwiftUI
import OSLog

enum Destination: String, CaseIterable, Identifiable {
    case home, reels, messages
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .reels: "Reels"
        case .messages: "Messages"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .reels: "play.rectangle.on.rectangle"
        case .messages: "paperplane"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .home: "1"
        case .reels: "2"
        case .messages: "3"
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
        didSet { visited.insert(destination) }
    }
    /// Pages opened at least once: only these are built (a page never visited loads nothing).
    private(set) var visited: Set<Destination> = [.messages]
    /// The story viewer, when open.
    var stories: StoryViewerModel?
    /// A post opened from a DM or elsewhere, shown over the current page.
    var openedMedia: Media?
    /// Shown as a small banner (errors, "copied").
    var toast: String?

    private(set) var feed: FeedModel?
    private(set) var reels: ReelsModel?
    private(set) var inbox: InboxModel?

    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Instagram", category: "App")

    init() {
        if let session = IGSession.restore() { start(IGClient(session: session)) }
        #if DEBUG
        // `-IGStartPage home|reels|messages`: open on that page (for screenshots).
        if let raw = UserDefaults.standard.string(forKey: "IGStartPage"), let d = Destination(rawValue: raw) {
            destination = d
        }
        #endif
    }

    private func start(_ client: IGClient) {
        self.client = client
        authState = .signedIn
        feed = FeedModel(app: self, client: client)
        reels = ReelsModel(app: self, client: client)
        inbox = InboxModel(app: self, client: client)
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
