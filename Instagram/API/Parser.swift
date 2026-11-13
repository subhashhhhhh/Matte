import Foundation

/// Instagram JSON → models. Field names follow the v1 media dict, which feed, reels,
/// stories and DMs all share; the containers around it are found by key, not fixed paths.
nonisolated enum Parser {
    // MARK: Users and media

    /// A string id that may arrive as a string or a number.
    static func idString(_ j: JSON) -> String? {
        if let s = j.string { return s }
        return j.int.map(String.init)
    }

    static func user(_ j: JSON) -> User? {
        guard let id = idString(j["pk"]) ?? idString(j["id"]), let username = j["username"].string else { return nil }
        let f = j["friendship_status"]
        return User(id: id, username: username, fullName: j["full_name"].string ?? "",
                    avatar: (j["profile_pic_url"].string).flatMap(URL.init(string:)),
                    isVerified: j["is_verified"].bool ?? false,
                    messagingId: idString(j["interop_messaging_user_fbid"]),
                    latestStory: j["latest_reel_media"].int.flatMap { $0 > 0 ? $0 : nil },
                    following: f["following"].bool ?? j["followed_by_viewer"].bool,
                    requested: f["outgoing_request"].bool ?? j["requested_by_viewer"].bool)
    }

    /// A business or creator account: `is_professional_account`, or `account_type` 2 (business) /
    /// 3 (creator); 1 is personal (seen in PolarisProfilePageContentQuery, 2026-11-13).
    static func isProfessional(_ j: JSON) -> Bool {
        if j["is_professional_account"].bool == true || j["is_business"].bool == true { return true }
        if let type = j["account_type"].int { return type == 2 || type == 3 }
        return false
    }

    /// A photo post's song (`music_metadata.music_info`, seen in `media/<pk>/info/`).
    /// A reel's audio label: the song it uses, or "Original audio" by whoever made it.
    static func audioName(_ clips: JSON) -> AudioName? {
        let song = clips["music_info"]["music_asset_info"]
        if let title = song["title"].string, !title.isEmpty {
            return AudioName(title: title, artist: song["display_artist"].string ?? "")
        }
        let original = clips["original_sound_info"]
        if let title = original["original_audio_title"].string, !title.isEmpty {
            return AudioName(title: title, artist: original["ig_artist"]["username"].string ?? "")
        }
        return nil
    }

    static func music(_ info: JSON) -> MusicTrack? {
        let asset = info["music_asset_info"], use = info["music_consumption_info"]
        guard let raw = asset["progressive_download_url"].string ?? asset["fast_start_progressive_download_url"].string,
              let url = URL(string: raw) else { return nil }
        if use["should_mute_audio"].bool == true { return nil }
        return MusicTrack(title: asset["title"].string ?? "", artist: asset["display_artist"].string ?? "", url: url,
                          startMs: use["audio_asset_start_time_in_ms"].int ?? asset["highlight_start_times_in_ms"].array.first?.int ?? 0,
                          durationMs: use["overlap_duration_in_ms"].int ?? 15000,
                          cover: asset["cover_artwork_thumbnail_uri"].string.flatMap(URL.init(string:)))
    }

    /// A story item's tappable stickers (shapes as seen in story responses, 2026-11-13).
    static func storyStickers(_ j: JSON) -> [StorySticker] {
        func place(_ s: JSON, _ kind: StorySticker.Kind) -> StorySticker? {
            guard let x = s["x"].double, let y = s["y"].double else { return nil }
            return StorySticker(kind: kind, x: x, y: y, width: s["width"].double ?? 0.3, height: s["height"].double ?? 0.1,
                                rotation: s["rotation"].double ?? 0)
        }
        var out: [StorySticker] = []
        for s in j["story_feed_media"].array {
            // `id` is not the post's pk; its shortcode is, encoded.
            guard let code = s["media_code"].string, let pk = Media.pk(fromCode: code) else { continue }
            if let st = place(s, .post(pk: pk, code: code, isReel: s["product_type"].string == "clips")) { out.append(st) }
        }
        for s in j["story_bloks_stickers"].array {
            if let u = s["bloks_sticker"]["sticker_data"]["ig_mention"]["username"].string, let st = place(s, .mention(username: u)) {
                out.append(st)
            }
        }
        for s in j["reel_mentions"].array {
            if let u = s["user"]["username"].string, let st = place(s, .mention(username: u)) { out.append(st) }
        }
        for s in j["story_link_stickers"].array {
            if let raw = s["story_link"]["url"].string, let url = URL(string: raw), let st = place(s, .link(url)) { out.append(st) }
        }
        for s in j["story_hashtags"].array {
            if let h = s["hashtag"]["name"].string, let st = place(s, .hashtag(h)) { out.append(st) }
        }
        return out
    }

    /// "<pk>_<owner id>" → pk; nil for anything else.
    static func pkFromMediaId(_ id: String) -> String? {
        let parts = id.split(separator: "_")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return String(parts[0])
    }

    static func media(_ j: JSON) -> Media? {
        // Some lists (a profile's Tagged tab) give carousel photos only an `id` ("<pk>_<owner>").
        guard let pk = j["pk"].string ?? j["pk"].int.map(String.init)
                ?? j["id"].string.flatMap(Self.pkFromMediaId) else { return nil }
        let type = j["media_type"].int ?? 1
        var m = Media(id: j["id"].string ?? pk, pk: pk, code: j["code"].string,
                      kind: Media.Kind(rawValue: type) ?? .image)
        m.user = user(j["user"]) ?? user(j["owner"])
        m.coauthors = j["coauthor_producers"].array.compactMap(user).filter { $0.id != m.user?.id }
        m.caption = j["caption"]["text"].string
        m.takenAt = j["taken_at"].double.map { Date(timeIntervalSince1970: $0) }
        m.expiresAt = j["expiring_at"].double.map { Date(timeIntervalSince1970: $0) }
        m.likeCount = j["like_count"].int
        m.commentCount = j["comment_count"].int
        m.viewCount = j["play_count"].int ?? j["view_count"].int
        m.hasLiked = j["has_liked"].bool ?? false
        m.hasSaved = j["has_viewer_saved"].bool ?? false
        m.countsHidden = j["like_and_view_counts_disabled"].bool ?? false
        for context in j["social_context"].array where context["social_context_type"].string == "liked_by" {
            m.likedBy = context["social_context_facepile_users"].array.compactMap(user)
            m.likedByCount = context["social_context_users_count"].int
        }
        if m.likedBy.isEmpty {
            // Pictures only (no names): still worth the bubbles.
            m.likedBy = j["facepile_top_likers"].array.compactMap { u in
                guard let id = idString(u["pk"]) ?? idString(u["id"]) else { return nil }
                return User(id: id, username: u["username"].string ?? "", fullName: "",
                            avatar: u["profile_pic_url"].string.flatMap(URL.init(string:)))
            }
        }
        m.topLikers = j["top_likers"].array.compactMap(\.string)
        m.repostCount = j["media_repost_count"].int
        m.storyViewerCount = j["viewer_count"].int ?? j["total_viewer_count"].int
        m.storyViewers = j["viewers"].array.compactMap { u in
            guard let id = idString(u["pk"]) ?? idString(u["id"]) else { return nil }
            return User(id: id, username: u["username"].string ?? "", fullName: u["full_name"].string ?? "",
                        avatar: u["profile_pic_url"].string.flatMap(URL.init(string:)))
        }
        m.repostNotes = j["media_notes"]["items"].array.compactMap { n in
            guard let id = idString(n["id"]), let user = idString(n["user_id"]) else { return nil }
            // Some responses give the reposter without a username: keep the picture anyway.
            let u = n["user"]
            let who = Parser.user(u) ?? User(id: user, username: u["username"].string ?? "", fullName: u["full_name"].string ?? "",
                                             avatar: u["profile_pic_url"].string.flatMap(URL.init(string:)))
            return RepostNote(id: id, userId: user, user: who,
                              text: n["text"].string.flatMap { $0.isEmpty ? nil : $0 })
        }
        m.storyStickers = storyStickers(j)
        m.music = music(j["music_metadata"]["music_info"])
        m.audioName = audioName(j["clips_metadata"])
        m.trackingToken = j["organic_tracking_token"].string
        m.loggingToken = j["logging_info_token"].string
        m.images = renditions(j["image_versions2"]["candidates"])
        m.videos = renditions(j["video_versions"])
        m.hasAudio = j["has_audio"].bool ?? true
        m.width = j["original_width"].int ?? m.images.first?.width ?? 1
        m.height = j["original_height"].int ?? m.images.first?.height ?? 1
        m.productType = j["product_type"].string
        m.commentsDisabled = j["comments_disabled"].bool
        if !j["usertags"].isNull { m.hasUsertags = !j["usertags"]["in"].array.isEmpty }
        let tags = j["usertags"]["in"].array.compactMap { t -> UserTag? in
            let p = t["position"].array
            guard let u = user(t["user"]), p.count == 2, let x = p[0].double, let y = p[1].double else { return nil }
            return UserTag(user: u, x: min(1, max(0, x)), y: min(1, max(0, y)))
        }
        if !tags.isEmpty { m.userTags = tags }
        let grid = j["timeline_pinned_user_ids"].array.compactMap(idString)
        if !grid.isEmpty { m.pinnedOnGrid = grid }
        let reels = j["clips_tab_pinned_user_ids"].array.compactMap(idString)
        if !reels.isEmpty { m.pinnedOnReels = reels }
        let inCollections = j["saved_collection_ids"].array.compactMap(idString)
        if !inCollections.isEmpty { m.savedCollectionIds = inCollections }
        m.children = j["carousel_media"].array.compactMap(media)
        if m.kind == .carousel, m.images.isEmpty, let first = m.children.first {
            m.images = first.images
            m.width = first.width
            m.height = first.height
        }
        return m
    }

    static func renditions(_ j: JSON) -> [Rendition] {
        j.array.compactMap { r in
            guard let s = r["url"].string, let url = URL(string: s) else { return nil }
            return Rendition(url: url, width: r["width"].int ?? 0, height: r["height"].int ?? 0)
        }
    }

    // MARK: Feed and reels

    /// A Relay connection of `{node: {media: …}}` edges (home feed, reels).
    /// `nodeIsMedia`: each edge's node is the post itself (profiles) rather than a unit
    /// holding it under `media` (feed, reels).
    static func mediaConnection(_ data: JSON, root: String, nodeIsMedia: Bool = false) -> Page<Media> {
        let conn = data.first(root) ?? .null
        let items = conn["edges"].array.compactMap { edge -> Media? in
            let node = edge["node"]
            // Suggested posts (home feed) come as their own unit, `explore_story.media`.
            let suggestion = nodeIsMedia ? JSON.null : node["explore_story"]["media"]
            let m = nodeIsMedia ? node : (node["media"].isNull ? suggestion : node["media"])
            // Ads and other units: no `media`, or one marked as an ad.
            guard !m.isNull, node["ad"].isNull, m["ad_id"].isNull, m["product_type"].string != "ad" else { return nil }
            var item = media(m)
            if !suggestion.isNull { item?.suggested = true }
            return item
        }
        let info = conn["page_info"]
        return Page(items: dedupe(items), cursor: info["end_cursor"].string, hasMore: info["has_next_page"].bool ?? false)
    }

    private static func dedupe(_ items: [Media]) -> [Media] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.pk).inserted }
    }

    // MARK: Stories

    static func storyTray(_ data: JSON) -> [StoryReel] {
        let tray = data.first("tray")?.array ?? []
        return tray.compactMap { r in
            guard let u = user(r["user"]) else { return nil }
            let id = r["id"].string ?? r["id"].int.map(String.init) ?? u.id
            let latest = r["latest_reel_media"].int ?? 0
            let seenAt = r["seen"].int ?? 0
            var reel = StoryReel(id: id, user: u, seen: latest > 0 && seenAt >= latest,
                                 latest: latest > 0 ? Date(timeIntervalSince1970: TimeInterval(latest)) : nil)
            reel.seenUpTo = seenAt > 0 ? Date(timeIntervalSince1970: TimeInterval(seenAt)) : nil
            return reel
        }
    }

    static func storyReels(_ data: JSON) -> [StoryReel] {
        let reels = data.first("reels_media")?.array ?? []
        return reels.compactMap { r in
            guard let u = user(r["user"]) ?? user(r["owner"]) else { return nil }
            let id = r["id"].string ?? r["id"].int.map(String.init) ?? u.id
            let items = r["items"].array.compactMap(media).map { m -> Media in
                var m = m
                if m.user == nil { m.user = u }
                return m
            }
            let seen = r["seen"].int ?? 0
            let latest = r["latest_reel_media"].int ?? 0
            return StoryReel(id: id, user: u, seen: latest > 0 && seen >= latest,
                             latest: latest > 0 ? Date(timeIntervalSince1970: TimeInterval(latest)) : nil, items: items)
        }
    }

    // MARK: DMs

    static func inbox(_ data: JSON) -> (threads: [DMThread], cursor: String?, hasMore: Bool) {
        let box = data.first("threads_by_folder") ?? .null
        let threads = box["edges"].array.compactMap { thread($0["node"]["as_ig_direct_thread"]) }
        return (threads, box["page_info"]["end_cursor"].string, box["page_info"]["has_next_page"].bool ?? false)
    }

    static func thread(_ t: JSON) -> DMThread? {
        guard let id = t["thread_fbid"].string ?? t["id"].string else { return nil }
        let users = t["users"].array.compactMap(user)
        let viewerMid = t["viewer"]["interop_messaging_user_fbid"].string
        var thread = DMThread(id: id, longId: t["thread_id"].string, threadKey: t["thread_key"].string, title: t["thread_title"].string ?? "",
                              users: users, isGroup: (t["is_group"].bool ?? false) || users.count > 1)
        if thread.title.isEmpty { thread.title = users.map(\.username).joined(separator: ", ") }
        thread.lastActivity = ms(t["last_activity_timestamp_ms"])
        thread.isMuted = t["is_muted"].bool ?? false
        thread.isPinned = t["is_pin"].bool ?? false
        thread.pinnedMessageIds = t["pinned_messages"].array.compactMap { $0["message_id"].string ?? $0["id"].string }
        let folder = t["system_folder"].string ?? ""
        thread.isRequest = folder == "PENDING" || folder == "SPAM"
        thread.imageURL = t["thread_image_url"].string.flatMap(URL.init(string:))
        thread.viewerMessagingId = viewerMid
        for r in t["slide_read_receipts"].array {
            if let who = r["participant_fbid"].string, let at = ms(r["watermark_timestamp_ms"]) { thread.readUpTo[who] = at }
        }
        if let newest = t["slide_messages"]["edges"].array.first.flatMap({ message($0["node"]) }) {
            thread.snippet = t["slide_messages"]["edges"][0]["node"]["igd_snippet"].string ?? newest.previewText
            thread.lastSenderIsViewer = newest.senderId == viewerMid
        }
        // Unread: our own watermark is older than the last activity (or it's marked unread).
        if let viewerMid, let last = thread.lastActivity {
            let mine = thread.readUpTo[viewerMid] ?? .distantPast
            thread.isUnread = !thread.lastSenderIsViewer && mine < last
        }
        if t["marked_as_unread"].bool == true { thread.isUnread = true }
        return thread
    }

    /// Messages newest first, as Instagram sends them, and the cursor for older ones.
    static func messages(_ conn: JSON) -> Page<DMMessage> {
        let items = conn["edges"].array.compactMap { message($0["node"]) }
        return Page(items: items, cursor: conn["page_info"]["end_cursor"].string,
                    hasMore: conn["page_info"]["has_next_page"].bool ?? false)
    }

    static func message(_ m: JSON) -> DMMessage? {
        guard let id = m["id"].string ?? m["message_id"].string else { return nil }
        let sender = m["sender_fbid"].string ?? m["sender"]["id"].string ?? ""
        var msg = DMMessage(id: id, senderId: sender, sentAt: ms(m["timestamp_ms"]) ?? .now, body: body(m))
        msg.offlineId = m["offline_threading_id"].string
        msg.isForwarded = m["igd_is_forwarded"].bool ?? false
        msg.isEdited = !m["slide_edit_history"].array.isEmpty
        msg.reactions = m["reactions"].array.compactMap { r in
            guard let e = r["reaction"].string else { return nil }
            return DMReaction(emoji: e, senderId: r["sender_fbid"].string ?? "")
        }
        let reply = m["replied_to_message"]
        if !reply.isNull, let rid = reply["id"].string ?? m["replied_to_message_id"].string {
            let preview = (reply["text_body"].string ?? message(reply)?.previewText) ?? ""
            msg.replyTo = .init(id: rid, senderId: reply["sender_fbid"].string ?? "", text: preview)
        }
        return msg
    }

    private static func body(_ m: JSON) -> DMMessage.Body {
        let c = m["content"]
        let text = m["text_body"].string.flatMap { $0.isEmpty ? nil : $0 }
        switch c["__typename"].string ?? "" {
        case "SlideMessageText":
            return .text(text ?? c["text_body"].string ?? "")
        case "SlideMessageImageContent":
            return .media(c["attachments"].array.compactMap { attachment($0, kind: .image) })
        case "SlideMessageVideosContent":
            return .media(c["videos"].array.compactMap { attachment($0, kind: .video) })
        case "SlideMessageMultiMediaContent":
            return .media(c["ordered_photo_video_attachments"].array.compactMap {
                attachment($0, kind: ($0["__typename"].string ?? "").contains("Video") || !$0["dash_manifest"].isNull ? .video : .image)
            })
        case "SlideMessageRavenImageContent", "SlideMessageRavenVideoContent":
            let kind: DMAttachment.Kind = c["__typename"].string == "SlideMessageRavenVideoContent" ? .video : .image
            if let a = attachment(c["attachment"], kind: kind) { return .media([a]) }
            return .notice(kind == .video ? "Video (opened)" : "Photo (opened)")
        case "SlideMessageAudiosContent":
            return .media(c["audio_attachments"].array.compactMap { a in
                guard let url = a["attachment_cdn_url"].string.flatMap(URL.init(string:)) else { return nil }
                return DMAttachment(kind: .audio, id: a["attachment_fbid"].string, url: url, durationMs: a["playable_duration_ms"].int)
            })
        case "SlideMessageAnimatedMediaContent":
            return .media(c["animated_media"].array.compactMap { a in
                let sticker = a["is_sticker"].bool ?? false
                let url = (sticker ? a["attachment_webp_url"].string : a["attachment_mp4_url"].string ?? a["attachment_webp_url"].string)
                    ?? a["preview_cdn_url"].string
                return DMAttachment(kind: sticker ? .sticker : .gif, url: url.flatMap(URL.init(string:)),
                                    preview: a["preview_cdn_url"].string.flatMap(URL.init(string:)),
                                    width: a["preview_width"].int ?? 0, height: a["preview_height"].int ?? 0)
            })
        case let t where t.hasSuffix("StickerContent") || t.hasSuffix("StickerXMAContent") && t != "SlideMessageMusicStickerXMAContent":
            return .media([DMAttachment(kind: .sticker, url: c["preview_url"].string.flatMap(URL.init(string:)),
                                        width: c["preview_width"].int ?? 0, height: c["preview_height"].int ?? 0)])
        case "SlideMessageXMAContent", "SlideMessageMusicStickerXMAContent":
            let x = c["xma"]
            let xmaText = c["xma_text_body"].string.flatMap { $0.isEmpty ? nil : $0 }
            if x.isNull || (x["target_id"].string ?? "").isEmpty && x["preview_image"].isNull {
                // A text message whose link got a preview card.
                return .text(xmaText ?? text ?? x["target_url"].string ?? "")
            }
            let image = x["preview_image"].isNull ? x["xmaPreviewImage"] : x["preview_image"]
            let share = DMShare(title: x["title_text"].string ?? x["header_title_text"].string ?? x["xmaHeaderTitle"].string,
                                subtitle: x["subtitle_text"].string, caption: x["caption_body_text"].string,
                                eyebrow: x["eyebrow_text"].string,
                                preview: (image["url"].string ?? image["fallback_url"].string).flatMap(URL.init(string:)),
                                previewWidth: image["width"].int ?? 0, previewHeight: image["height"].int ?? 0,
                                targetURL: x["target_url"].string.flatMap(URL.init(string:)), targetId: x["target_id"].string,
                                headerIcon: x["header_icon"]["url"].string.flatMap(URL.init(string:)))
            return .share(share, text: xmaText)
        case "SlideMessageAdminText":
            let parts = c["text_fragments"].array.compactMap { $0["plaintext"].string }.joined()
            return .notice(parts.isEmpty ? (text ?? "") : parts)
        default:
            if let text { return .text(text) }
            return .unsupported(m["igd_snippet"].string ?? "Open Instagram to see this message")
        }
    }

    private static func attachment(_ a: JSON, kind: DMAttachment.Kind) -> DMAttachment? {
        guard !a.isNull else { return nil }
        let url = (a["attachment_cdn_url"].string ?? a["attachment_cdn_fallback_url"].string).flatMap(URL.init(string:))
        let preview = (a["preview_cdn_url"].string ?? a["preview_cdn_fallback_url"].string).flatMap(URL.init(string:))
        guard url != nil || preview != nil else { return nil }
        return DMAttachment(kind: kind, id: a["attachment_fbid"].string, url: url ?? preview, preview: preview ?? url,
                            width: a["preview_width"].int ?? 0, height: a["preview_height"].int ?? 0)
    }

    static func ms(_ j: JSON) -> Date? {
        j.double.map { Date(timeIntervalSince1970: $0 / 1000) }
    }
}
