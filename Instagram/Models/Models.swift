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

/// One repost of a media (Instagram calls them media notes).
/// Something tappable on a story, where it sits as fractions of the story (centre and size).
nonisolated struct StorySticker: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// A shared post or reel (`story_feed_media`).
        case post(pk: String, code: String?, isReel: Bool)
        /// A mention (`story_bloks_stickers` → `ig_mention`, or `reel_mentions`).
        case mention(username: String)
        /// A link sticker (`story_link_stickers`).
        case link(URL)
        /// A hashtag sticker (`story_hashtags`).
        case hashtag(String)
    }

    var kind: Kind
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var rotation: Double = 0

    var title: String {
        switch kind {
        case .post(_, _, let isReel): isReel ? "View reel" : "View post"
        case .mention(let u): "View profile · \(u)"
        case .link(let url): url.host().map { "Open \($0)" } ?? "Open link"
        case .hashtag(let h): "#\(h)"
        }
    }
}

/// A song on a photo post: the part the poster picked (`audio_asset_start_time_in_ms`,
/// `overlap_duration_in_ms`) of `progressive_download_url`.
nonisolated struct MusicTrack: Hashable, Sendable {
    var title: String
    var artist: String
    var url: URL
    var startMs: Int
    var durationMs: Int
    var cover: URL?
}

nonisolated struct RepostNote: Hashable, Sendable {
    var id: String
    var userId: String
    /// Who reposted (for the bubbles) and the thought they added, if any.
    var user: User?
    var text: String?
}

/// Someone tagged in a photo: the spot is a fraction of the photo's width and height.
nonisolated struct UserTag: Hashable, Sendable {
    var user: User
    var x: Double
    var y: Double
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
    /// Collab posts: the other authors (Instagram shows "owner and 2 others").
    var coauthors: [User] = []
    var caption: String?
    var takenAt: Date?
    /// Stories: when it disappears.
    var expiresAt: Date?
    var likeCount: Int?
    var commentCount: Int?
    var viewCount: Int?
    var hasLiked = false
    var hasSaved = false
    /// The owner hides like and view counts (`likeCount` is then only friends' likes).
    var countsHidden = false
    /// People you follow who liked it (Instagram's "Liked by … and others" bubbles).
    var likedBy: [User] = []
    var likedByCount: Int?
    /// Usernames Instagram names as likers when it has no profile pictures for them.
    var topLikers: [String] = []
    var repostCount: Int?
    /// Your own story: how many people viewed it, and the first few of them.
    var storyViewerCount: Int?
    var storyViewers: [User] = []
    /// Reposts shown with the media (`media_notes.items`): who reposted it, and the repost's
    /// note id (removing your repost takes it).
    var repostNotes: [RepostNote] = []
    /// `organic_tracking_token`: the web app sends it with a like.
    var trackingToken: String?
    /// `logging_info_token`: the web app sends it with a save.
    var loggingToken: String?
    var images: [Rendition] = []
    var videos: [Rendition] = []
    var hasAudio = true
    var width: Int = 1
    var height: Int = 1
    var children: [Media] = []
    var productType: String?
    /// The owner turned commenting off (`comments_disabled`), when the response says.
    var commentsDisabled: Bool?
    /// People are tagged in it (`usertags.in`), when the response says.
    var hasUsertags: Bool?
    /// Stories: what can be tapped on it (a shared post, a mention, a link, a hashtag).
    var storyStickers: [StorySticker] = []
    /// A photo post's song (`music_metadata`; only the post's own info has it, not the feed).
    var music: MusicTrack?
    /// A home-feed post from someone you don't follow, mixed in by Instagram (an
    /// `explore_story` unit; the website marks it "Suggested for you"). Optional so cached
    /// feeds from before still decode.
    var suggested: Bool?
    /// People tagged in the photo (`usertags.in`), where they were tagged. Optional so cached
    /// posts from before still decode.
    var userTags: [UserTag]?

    /// A shortcode's media pk (the code is the pk in Instagram's URL-safe base 64; longer
    /// codes of private posts carry extra characters after the first 11).
    static func pk(fromCode code: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var n: UInt64 = 0
        for ch in code.prefix(11) {
            guard let i = alphabet.firstIndex(of: ch) else { return nil }
            let (shifted, o1) = n.multipliedReportingOverflow(by: 64)
            let (sum, o2) = shifted.addingReportingOverflow(UInt64(i))
            if o1 || o2 { return nil }
            n = sum
        }
        return n > 0 ? String(n) : nil
    }

    /// Width over height, clamped to what a layout can show sensibly.
    var aspect: CGFloat { CGFloat(width) / CGFloat(max(height, 1)) }

    /// The smallest image at least `pixels` wide (or the largest there is), in the post's own
    /// shape: Instagram also lists square crops (for grids), which would cut a 4:5 or 9:16
    /// photo top and bottom.
    func image(minWidth pixels: CGFloat) -> URL? {
        let shaped = images.filter { r in
            guard r.width > 0, r.height > 0, width > 1, height > 1 else { return false }
            return abs(CGFloat(r.width) / CGFloat(r.height) - aspect) <= aspect * 0.03
        }
        let sorted = (shaped.isEmpty ? images : shaped).sorted { $0.width < $1.width }
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
    /// Instagram's seen marker: stories posted after it are the unseen ones.
    var seenUpTo: Date?
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
    /// Messages pinned to the top of the chat (`pinned_messages`).
    var pinnedMessageIds: [String] = []
    var isRequest = false
    var imageURL: URL?
    /// Each participant's read watermark, by messaging id.
    var readUpTo: [String: Date] = [:]
    var viewerMessagingId: String?

    var avatarUsers: [User] { Array(users.prefix(2)) }
}

/// Someone's activity status, as the web app shows it ("Active now" / "Active 12m ago").
/// Keyed everywhere by messaging id (`User.messagingId`, `interop_messaging_user_fbid`).
nonisolated struct Presence: Hashable, Sendable {
    /// Online right now.
    var isActive: Bool
    /// When they were last active (nil if Instagram doesn't say).
    var lastActive: Date?
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
    var liked = false
    /// A GIF comment (its text is empty).
    var gif: GIF?
    /// Set on replies: the comment they answer.
    var parentId: String?

    nonisolated struct GIF: Hashable, Sendable {
        var mp4: URL?
        var still: URL?
        var width: Int
        var height: Int
    }
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
        // Posts are linked by shortcode only (/p/<code>/): the code is the id in base 64.
        let parts = url.pathComponents.filter { $0 != "/" }
        if parts.count >= 2, ["p", "reel", "reels", "tv"].contains(parts[0]) { return Self.pk(fromShortcode: parts[1]) }
        return nil
    }

    /// Instagram's shortcode → numeric media id (base 64 over `A–Z a–z 0–9 - _`). Long codes of
    /// private posts carry extra characters after the first 11; nil if it doesn't decode.
    static func pk(fromShortcode code: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let chars = Array(code.prefix(11))
        guard !chars.isEmpty else { return nil }
        var value: UInt64 = 0
        for c in chars {
            guard let i = alphabet.firstIndex(of: c) else { return nil }
            let (shifted, o1) = value.multipliedReportingOverflow(by: 64)
            let (sum, o2) = shifted.addingReportingOverflow(UInt64(i))
            guard !o1, !o2 else { return nil }
            value = sum
        }
        return value > 0 ? String(value) : nil
    }
}

// MARK: - Profiles, search

/// A profile's header: who they are and their counts.
nonisolated struct Profile: Hashable, Sendable {
    var user: User
    var biography: String?
    var category: String?
    var externalURL: URL?
    var postCount: Int?
    var followerCount: Int?
    var followingCount: Int?
    var mutualFollowers: Int?
    var isPrivate = false
    /// A business or creator account (what Instagram's scheduling and insights need). Nil in
    /// profiles cached before this was read.
    var isProfessional: Bool?
    var following = false
    var followedBy = false
    /// A follow request to this (private) account is waiting.
    var requested = false
    var hdAvatar: URL?
}

/// What the search box finds.
nonisolated struct SearchResults: Sendable {
    var users: [User] = []
    var hashtags: [Hashtag] = []
}

nonisolated struct Hashtag: Hashable, Sendable, Identifiable {
    var id: String { name }
    var name: String
    var mediaCount: Int?
}

// MARK: - Cached on disk (ResponseCache)

// Synthesized: a field added later makes older cache files fail to decode, which the cache
// treats as a miss (it never fails the app).
extension User: Codable {}
extension Rendition: Codable {}
extension Media.Kind: Codable {}
extension RepostNote: Codable {}
extension StorySticker.Kind: Codable {}
extension StorySticker: Codable {}
extension MusicTrack: Codable {}
extension UserTag: Codable {}
extension Media: Codable {}
extension StoryReel: Codable {}
extension DMThread: Codable {}
extension Profile: Codable {}
