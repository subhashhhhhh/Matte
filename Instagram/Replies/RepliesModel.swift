import SwiftUI
import OSLog

/// Replies (Manager mode): the comments on the account's recent posts in one list, newest
/// first, with the ones still waiting for your answer picked out. Replying, liking and saved
/// replies happen right here, without opening each post.
@Observable
final class RepliesModel {
    enum Filter: String, CaseIterable, Identifiable {
        case needsReply, all
        var id: String { rawValue }
        var title: String { self == .needsReply ? "Needs reply" : "All comments" }
    }

    struct Item: Identifiable, Equatable {
        var comment: IGComment
        var post: Media
        /// You (the account) have replied to it, or it's yours.
        var answered: Bool
        var id: String { comment.id }
        static func == (a: Item, b: Item) -> Bool { a.comment == b.comment && a.post.pk == b.post.pk && a.answered == b.answered }
    }

    /// How many recent posts are read, and how many comments' replies are checked per refresh.
    static let postLimit = 12
    static let replyCheckLimit = 25

    private(set) var items: [Item] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var problem: String?
    private(set) var lastRefresh: Date?
    var filter: Filter = .needsReply
    /// A typed reply per comment (kept while you switch between them).
    var drafts: [String: String] = [:]
    private(set) var sending: Set<String> = []
    /// Reusable answers (Settings-free: added and removed here), kept on this Mac.
    private(set) var savedReplies: [String] = UserDefaults.standard.stringArray(forKey: "savedReplies") ?? []

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let client: IGClient
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Matte", category: "Replies")

    init(app: AppModel?, client: IGClient) {
        self.app = app
        self.client = client
    }

    var shown: [Item] { filter == .all ? items : items.filter { !$0.answered } }
    var waitingCount: Int { items.filter { !$0.answered }.count }

    func loadIfNeeded() async {
        guard !loaded else { return }
        await refresh()
    }

    func refresh() async {
        guard !loading, let app else { return }
        loading = true
        defer { loading = false; MemoryRelief.soon() }
        do {
            // At launch the app may still be loading your profile: ask for it directly then.
            let me: User
            if let m = app.me { me = m } else {
                guard let id = await client.session.userId else { throw IGError.signedOut }
                me = try await client.profile(id: id).user
            }
            var username = me.username
            #if DEBUG
            // `-IGRepliesUser <username>`: read another (public) account's comments, for screenshots.
            if let other = UserDefaults.standard.string(forKey: "IGRepliesUser") { username = other }
            #endif
            let posts = try await client.profilePosts(username: username).items
                .prefix(Self.postLimit)
                .filter { ($0.commentCount ?? 0) > 0 }
            var found: [Item] = []
            for post in posts {
                try Task.checkCancellation()
                guard let page = try? await client.comments(pk: post.pk) else { continue }
                for c in page.items.prefix(60) {
                    let mine = c.user?.id == me.id
                    found.append(Item(comment: c, post: post, answered: mine))
                }
            }
            // Someone else's comment is answered once one of its replies is yours (checked for
            // the newest few with replies; the rest stay listed as waiting).
            found.sort { ($0.comment.createdAt ?? .distantPast) > ($1.comment.createdAt ?? .distantPast) }
            var checked = 0
            for i in found.indices where !found[i].answered && found[i].comment.replyCount > 0 && checked < Self.replyCheckLimit {
                checked += 1
                if let replies = try? await client.replies(media: found[i].post.pk, comment: found[i].comment.id) {
                    found[i].answered = replies.items.contains { $0.user?.id == me.id }
                }
            }
            items = found
            problem = nil
            loaded = true
            lastRefresh = .now
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            if case IGError.signedOut = error { app.report(error); return }
            log.error("Replies failed: \(error.localizedDescription, privacy: .public)")
            loaded = true
            problem = error.localizedDescription
        }
    }

    func draft(for item: Item) -> String { drafts[item.id] ?? "" }

    /// What's posted: the draft, starting with "@name " as Instagram's replies do (unless the
    /// draft already names them).
    static func replyText(_ draft: String, to user: User?) -> String {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let name = user?.username, !text.lowercased().contains("@" + name.lowercased()) else { return text }
        return "@\(name) " + text
    }

    func send(_ item: Item) async {
        let text = Self.replyText(draft(for: item), to: item.comment.user)
        guard !text.isEmpty, !sending.contains(item.id) else { return }
        sending.insert(item.id)
        defer { sending.remove(item.id) }
        do {
            _ = try await client.postComment(text, media: item.post.pk, replyTo: item.comment.id)
            drafts[item.id] = nil
            if let i = items.firstIndex(where: { $0.id == item.id }) {
                items[i].answered = true
                items[i].comment.replyCount += 1
            }
            app?.show("Reply posted")
        } catch {
            app?.report(error)
        }
    }

    func toggleLike(_ item: Item) async {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        let liked = !items[i].comment.liked
        items[i].comment.liked = liked
        items[i].comment.likeCount += liked ? 1 : -1
        do {
            try await client.setCommentLiked(liked, comment: item.comment.id)
        } catch {
            if let j = items.firstIndex(where: { $0.id == item.id }) {
                items[j].comment.liked = !liked
                items[j].comment.likeCount += liked ? -1 : 1
            }
            app?.report(error)
        }
    }

    /// Marks a comment as dealt with without replying (until the next refresh finds it again).
    func markDone(_ item: Item) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].answered = true }
    }

    // MARK: Saved replies

    func useSaved(_ text: String, for item: Item) {
        let current = draft(for: item)
        drafts[item.id] = current.isEmpty || current.hasSuffix(" ") ? current + text : current + " " + text
    }

    func save(reply text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !savedReplies.contains(t), savedReplies.count < 30 else { return }
        savedReplies.append(t)
        UserDefaults.standard.set(savedReplies, forKey: "savedReplies")
    }

    func removeSaved(_ text: String) {
        savedReplies.removeAll { $0 == text }
        UserDefaults.standard.set(savedReplies, forKey: "savedReplies")
    }
}
