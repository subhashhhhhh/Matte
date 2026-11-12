import Foundation

/// An Instagram account, as it appears on posts, stories, reels and in DMs.
nonisolated struct User: Hashable, Sendable, Identifiable {
    var id: String
    var username: String
    var fullName: String
    var avatar: URL?
    var isVerified = false
    /// Messaging id (`interop_messaging_user_fbid`): how DMs name senders.
    var messagingId: String?
    /// Newest story time (Unix seconds), when the account has an active story.
    var latestStory: Int?

    var displayName: String { fullName.isEmpty ? username : fullName }
}

/// One image or video rendition.
nonisolated struct Rendition: Hashable, Sendable {
    var url: URL
    var width: Int
    var height: Int
}

/// A post, reel, story item or carousel child: Instagram's one media shape.
nonisolated struct Media: Hashable, Sendable, Identifiable {
    enum Kind: Int, Sendable { case image = 1, video = 2, carousel = 8 }

    var id: String
    /// Numeric media id (`pk`).
    var pk: String
    /// Shortcode for links (`instagram.com/p/<code>`).
    var code: String?
    var kind: Kind
    var user: User?
    var caption: String?
    var takenAt: Date?
    /// Stories: when it disappears.
    var expiresAt: Date?
    var likeCount: Int?
    var commentCount: Int?
    var viewCount: Int?
    var hasLiked = false
    var hasSaved = false
    var images: [Rendition] = []
    var videos: [Rendition] = []
    var hasAudio = true
    var width: Int = 1
    var height: Int = 1
    var children: [Media] = []
    var productType: String?

    /// Width over height, clamped to what a layout can show sensibly.
    var aspect: CGFloat { CGFloat(width) / CGFloat(max(height, 1)) }

    /// The smallest image at least `pixels` wide (or the largest there is).
    func image(minWidth pixels: CGFloat) -> URL? {
        let sorted = images.sorted { $0.width < $1.width }
        return (sorted.first { CGFloat($0.width) >= pixels } ?? sorted.last)?.url
    }

    /// The video to play: the smallest rendition at least `pixels` wide, so a phone-sized
    /// window doesn't stream (and buffer) the full-size file.
    func video(minWidth pixels: CGFloat) -> URL? {
        let sorted = videos.sorted { $0.width < $1.width }
        return (sorted.first { CGFloat($0.width) >= pixels } ?? sorted.last)?.url
    }

    var isVideo: Bool { kind == .video || !videos.isEmpty }
    var webURL: URL? { code.map { URL(string: "https://www.instagram.com/p/\($0)/")! } }
}

/// One account's stories in the tray.
nonisolated struct StoryReel: Hashable, Sendable, Identifiable {
    var id: String
    var user: User
    var seen: Bool
    var latest: Date?
    /// Filled when the reel is opened.
    var items: [Media] = []
}

/// A page of results and where the next one starts.
nonisolated struct Page<T: Sendable>: Sendable {
    var items: [T]
    var cursor: String?
    var hasMore: Bool
}

// MARK: - DMs

nonisolated struct DMThread: Hashable, Sendable, Identifiable {
    /// The thread IGID (`thread_fbid` / `id`): what every DM query and mutation takes.
    var id: String
    /// The "long" thread id (`thread_id`): mark-read and unsend take this one.
    var longId: String?
    var threadKey: String?
    var title: String
    var users: [User]
    var isGroup: Bool
    var lastActivity: Date?
    var snippet: String?
    var lastSenderIsViewer = false
    var isUnread = false
    var isMuted = false
    var isPinned = false
    var isRequest = false
    var imageURL: URL?
    /// Each participant's read watermark, by messaging id.
    var readUpTo: [String: Date] = [:]
    var viewerMessagingId: String?

    var avatarUsers: [User] { Array(users.prefix(2)) }
}

nonisolated struct DMReaction: Hashable, Sendable {
    var emoji: String
    var senderId: String
}

nonisolated struct DMAttachment: Hashable, Sendable {
    enum Kind: Sendable, Hashable { case image, video, audio, gif, sticker }
    var kind: Kind
    var id: String?
    var url: URL?
    var preview: URL?
    var width: Int = 0
    var height: Int = 0
    var durationMs: Int?
    var aspect: CGFloat { width > 0 && height > 0 ? CGFloat(width) / CGFloat(height) : 1 }
}

/// A shared post, reel, story, story reply or link card.
nonisolated struct DMShare: Hashable, Sendable {
    var title: String?
    var subtitle: String?
    var caption: String?
    /// Quoted text above a story reply ("Replied to your story").
    var eyebrow: String?
    var preview: URL?
    var previewWidth: Int = 0
    var previewHeight: Int = 0
    var targetURL: URL?
    var targetId: String?
    var headerIcon: URL?

    var isReel: Bool { targetURL?.path().hasPrefix("/reel") ?? false }
    var isStory: Bool { targetURL?.path().hasPrefix("/stories/") ?? false }
}

nonisolated struct DMMessage: Hashable, Sendable, Identifiable {
    enum Body: Hashable, Sendable {
        case text(String)
        case media([DMAttachment])
        case share(DMShare, text: String?)
        case notice(String)
        case unsupported(String)
    }

    var id: String
    var senderId: String
    var sentAt: Date
    var body: Body
    var reactions: [DMReaction] = []
    var replyTo: ReplyPreview?
    var isEdited = false
    var isForwarded = false
    /// Set while a message we sent hasn't been confirmed.
    var pending = false
    var failed = false
    var offlineId: String?

    struct ReplyPreview: Hashable, Sendable {
        var id: String
        var senderId: String
        var text: String
    }

    var previewText: String {
        switch body {
        case .text(let t): t
        case .media(let a): a.first?.kind == .video ? "Video" : a.first?.kind == .audio ? "Voice message" : "Photo"
        case .share(let s, let text): text ?? (s.isReel ? "Shared a reel" : s.isStory ? "Shared a story" : "Shared a post")
        case .notice(let t): t
        case .unsupported(let t): t
        }
    }
}

/// A comment under a post or reel.
nonisolated struct IGComment: Hashable, Sendable, Identifiable {
    var id: String
    var user: User?
    var text: String
    var createdAt: Date?
    var likeCount = 0
    var replyCount = 0
}

extension DMShare {
    /// The shared post's media id: `?id=<pk>_<owner>` on post/reel links, the last path part on
    /// story links.
    var mediaPk: String? {
        guard let url = targetURL else { return nil }
        if let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
           let pk = id.split(separator: "_").first, pk.allSatisfy(\.isNumber) {
            return String(pk)
        }
        if isStory, let last = url.pathComponents.last(where: { $0 != "/" }), last.allSatisfy(\.isNumber) { return last }
        return nil
    }
}
