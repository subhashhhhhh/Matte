import Foundation

/// One post or reel by id, and its comments (REST endpoints that accept the web session).
extension IGClient {
    /// Like/save mutations live in scripts the web app loads on demand (not scanned), so their
    /// doc ids are kept here (read from the web app's scripts on 2026-11-12).
    nonisolated static let postActionDocIds: [String: String] = [
        "PolarisAPILikePostMutation": "28051398997871885",
        "PolarisAPIUnlikePostMutation": "29100661379564082",
        "PolarisAPISavePostMutation": "27326721586982367",
        "PolarisAPIUnsavePostMutation": "27203919972607144",
    ]

    private func postAction(_ name: String, pk: String) async throws {
        await prepare()
        let doc = knownOperations()[name] ?? Self.postActionDocIds[name]
        _ = try await graphQL(name, variables: ["input": ["media_id": .string(pk)]], docId: doc)
    }

    func setLiked(_ liked: Bool, pk: String) async throws {
        try await postAction(liked ? "PolarisAPILikePostMutation" : "PolarisAPIUnlikePostMutation", pk: pk)
    }

    func setSaved(_ saved: Bool, pk: String) async throws {
        try await postAction(saved ? "PolarisAPISavePostMutation" : "PolarisAPIUnsavePostMutation", pk: pk)
    }

    /// The replies under a comment, oldest first, a page at a time (as the web app's
    /// "View replies").
    func replies(media pk: String, comment id: String, cursor: String? = nil) async throws -> Page<IGComment> {
        var query = ["is_chronological": "true", "paging_direction": "view_more"]
        if let cursor { query["min_id"] = cursor }
        let json = try await rest(.get, "/api/v1/media/\(pk)/comments/\(id)/child_comments/", query: query)
        let items = json["child_comments"].array.compactMap(Parser.comment)
        let next = json["next_min_child_cursor"].string
        let more = (json["has_more_head_child_comments"].bool ?? false) || (json["has_more_tail_child_comments"].bool ?? false)
        return Page(items: items, cursor: next, hasMore: more && next != nil)
    }

    nonisolated static let commentDocIds: [String: String] = [
        "PolarisCommentActionsLikeMutation": "27184292767848867",
        "PolarisCommentActionsUnlikeMutation": "27318337671093716",
        "usePolarisCommentCreateMutation": "39617891021192323",
    ]

    func setCommentLiked(_ liked: Bool, comment id: String) async throws {
        let name = liked ? "PolarisCommentActionsLikeMutation" : "PolarisCommentActionsUnlikeMutation"
        await prepare()
        _ = try await graphQL(name, variables: ["input": ["comment_id": .string(id)]],
                              docId: knownOperations()[name] ?? Self.commentDocIds[name])
    }

    /// Posts a comment, or a reply when `replyTo` is a comment id. Returns the new comment.
    func postComment(_ text: String, media pk: String, replyTo: String? = nil) async throws -> IGComment? {
        let name = "usePolarisCommentCreateMutation"
        var data: [String: JSON] = ["comment_text": .string(text), "media_id": .string(pk)]
        if let replyTo, let n = Int64(replyTo) { data["replied_to_comment_id"] = .integer(n) }
        await prepare()
        let result = try await graphQL(name, variables: ["data": .object(data), "root_connections": .array([])],
                                       docId: knownOperations()[name] ?? Self.commentDocIds[name])
        return Parser.comment(result["xig_comment_create"])
    }

    /// Tells Instagram you watched a story item (you then appear in its viewers). Exactly what
    /// instagram.com sends when a story is shown (recorded 2026-11-12): `PolarisStoriesV3SeenMutation`
    /// with the bare media pk and every value as a string. `reelId` is the owner's id, or "highlight:…".
    func markStorySeen(reelId: String, media: Media) async throws {
        let name = "PolarisStoriesV3SeenMutation"
        await prepare()
        let owner = media.user?.id ?? (reelId.hasPrefix("highlight:") ? "" : reelId)
        let result = try await graphQL(name, variables: [
            "reelId": .string(reelId), "reelMediaId": .string(media.pk), "reelMediaOwnerId": .string(owner),
            "reelMediaTakenAt": .string(String(Int64(media.takenAt?.timeIntervalSince1970 ?? 0))),
            "viewSeenAt": .string(String(Int64(Date.now.timeIntervalSince1970))),
        ], docId: knownOperations()[name] ?? "26234228992942885")
        guard !result["xdt_mark_story_reel_seen"].isNull else { throw IGError.badResponse }
    }

    @ObservationIgnored nonisolated(unsafe) private static var storyLikeCounter = 0

    /// Likes or unlikes a story item. The like is exactly what instagram.com sends (recorded
    /// 2026-11-12): `usePolarisStoriesV4LikeMutationLikeMutation` with your actor id, a client
    /// counter and the bare media pk. Unlike: `usePolarisStoryLikesUnlikeMutation` (from the scripts).
    func setStoryLiked(_ liked: Bool, media: Media) async throws {
        await prepare()
        if liked {
            Self.storyLikeCounter += 1
            let name = "usePolarisStoriesV4LikeMutationLikeMutation"
            let r = try await graphQL(name, variables: ["input": [
                "actor_id": .string(page.actorId ?? ""), "client_mutation_id": .string(String(Self.storyLikeCounter)),
                "media_id": .string(media.pk),
            ]], docId: knownOperations()[name] ?? "26938887309082050")
            guard !r["xig_send_story_like"].isNull else { throw IGError.badResponse }
        } else {
            let name = "usePolarisStoryLikesUnlikeMutation"
            _ = try await graphQL(name, variables: ["input": ["media_id": .string(media.pk)]],
                                  docId: knownOperations()[name] ?? "28216363747963539")
        }
    }

    func mediaInfo(pk: String) async throws -> Media {
        let json = try await rest(.get, "/api/v1/media/\(pk)/info/")
        guard let media = Parser.media(json["items"][0]) else { throw IGError.badResponse }
        return media
    }

    /// A page of top-level comments, oldest cursor style the web app uses (`min_id`).
    func comments(pk: String, cursor: String? = nil) async throws -> Page<IGComment> {
        var query = ["can_support_threading": "true", "permalink_enabled": "false"]
        if let cursor { query["min_id"] = cursor }
        let json = try await rest(.get, "/api/v1/media/\(pk)/comments/", query: query)
        let items = json["comments"].array.compactMap(Parser.comment)
        let next = json["next_min_id"].string
        let more = (json["has_more_headload_comments"].bool ?? false) || (json["has_more_comments"].bool ?? false)
        return Page(items: items, cursor: next, hasMore: more && next != nil)
    }
}

nonisolated extension Parser {
    static func comment(_ j: JSON) -> IGComment? {
        guard let id = idString(j["pk"]) ?? idString(j["id"]) else { return nil }
        var c = IGComment(id: id, user: user(j["user"]), text: j["text"].string ?? "",
                          createdAt: j["created_at"].double.map { Date(timeIntervalSince1970: $0) },
                          likeCount: j["comment_like_count"].int ?? 0,
                          replyCount: j["child_comment_count"].int ?? 0)
        c.liked = j["has_liked_comment"].bool ?? false
        c.parentId = idString(j["parent_comment_id"])
        let g = j["giphy_media_info"]["images"]["fixed_height"]
        if !g.isNull {
            c.gif = .init(mp4: g["mp4"].string.flatMap(URL.init(string:)),
                          still: (g["webp"].string ?? g["url"].string).flatMap(URL.init(string:)),
                          width: g["width"].int ?? 200, height: g["height"].int ?? 200)
        }
        return c
    }
}
