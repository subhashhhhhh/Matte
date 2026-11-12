import Foundation

/// One post or reel by id, and its comments (REST endpoints that accept the web session).
extension IGClient {
    /// Doc ids of the post mutations, as instagram.com sent them (recorded 2026-11-12). A newer
    /// one read from the scripts wins.
    nonisolated static let postActionDocIds: [String: String] = [
        "usePolarisLikeMediaXIGLikeMutation": "27182485238052618",
        "usePolarisLikeMediaXIGUnlikeMutation": "27345296031770102",
        "usePolarisSaveMediaSaveMutation": "27365486596441074",
        "usePolarisSaveMediaUnsaveMutation": "27371251859134880",
        "usePolarisCreateMediaRepostMutation": "27933176649688558",
        "usePolarisDeleteMediaRepostMutation": "26656683127335602",
        "usePolarisUpdateMediaRepostMutation": "30190616567193660",
    ]

    private func doc(_ name: String) -> String? {
        knownOperations()[name] ?? Self.postActionDocIds[name] ?? Self.commentDocIds[name]
    }

    /// Likes or unlikes a post or reel, as instagram.com does (recorded): your actor id, the
    /// mutation counter, the bare media pk and the media's `organic_tracking_token`; the like
    /// also names the surface (`container_module`).
    func setLiked(_ liked: Bool, media m: Media, containerModule: String = "feed_timeline") async throws {
        await prepare()
        let name = liked ? "usePolarisLikeMediaXIGLikeMutation" : "usePolarisLikeMediaXIGUnlikeMutation"
        var fields: [String: JSON] = ["media_id": .string(m.pk)]
        if liked { fields["container_module"] = .string(containerModule) }
        if let t = m.trackingToken { fields["tracking_token"] = .string(t) }
        _ = try await graphQL(name, variables: ["input": mutationInput(fields)], docId: doc(name))
    }

    func setLiked(_ liked: Bool, pk: String) async throws {
        try await setLiked(liked, media: Media(id: pk, pk: pk, kind: .image))
    }

    /// Saves a post, or removes it from saved, as instagram.com does (both recorded). The save
    /// names the surface and the media's `logging_info_token`; the unsave sends only the pk.
    func setSaved(_ saved: Bool, media m: Media, containerModule: String = "feed_timeline") async throws {
        await prepare()
        if saved {
            let name = "usePolarisSaveMediaSaveMutation"
            var fields: [String: JSON] = ["container_module": .string(containerModule), "inventory_source": "media_or_ad",
                                          "media_id": .string(m.pk)]
            if let t = m.loggingToken { fields["logging_info_token"] = .string(t) }
            _ = try await graphQL(name, variables: ["input": mutationInput(fields)], docId: doc(name))
        } else {
            let name = "usePolarisSaveMediaUnsaveMutation"
            _ = try await graphQL(name, variables: ["input": mutationInput(["media_id": .string(m.pk)])], docId: doc(name))
        }
    }

    func setSaved(_ saved: Bool, pk: String) async throws {
        try await setSaved(saved, media: Media(id: pk, pk: pk, kind: .image))
    }

    // MARK: Reposts

    /// Reposts a post or reel to your profile (recorded): audience 7 and note style 13 (numbers),
    /// and an empty text, as the web app's repost button sends them. Returns the repost's note
    /// id, which removing or captioning it takes.
    func repost(media m: Media) async throws -> String {
        await prepare()
        let name = "usePolarisCreateMediaRepostMutation"
        let r = try await graphQL(name, variables: ["input": mutationInput([
            "audience": 7, "media_id": .string(m.pk), "note_style": 13, "text": "",
        ])], docId: doc(name))
        guard let id = Parser.idString(r["xdt_create_media_note_v2"]["id"]) else { throw IGError.badResponse }
        return id
    }

    /// Removes your repost (recorded): takes the repost's note id, not the media's.
    func deleteRepost(noteId: String) async throws {
        await prepare()
        let name = "usePolarisDeleteMediaRepostMutation"
        _ = try await graphQL(name, variables: ["input": mutationInput(["note_id": .string(noteId)])], docId: doc(name))
    }

    /// Adds or changes the text on your repost (recorded).
    func updateRepost(noteId: String, text: String) async throws {
        await prepare()
        let name = "usePolarisUpdateMediaRepostMutation"
        _ = try await graphQL(name, variables: ["input": mutationInput([
            "media_note_id": .string(noteId), "text": .string(text),
        ])], docId: doc(name))
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

    /// Comment create, like, unlike and delete, as recorded from instagram.com (2026-11-12).
    nonisolated static let commentDocIds: [String: String] = [
        "PolarisCommentActionsLikeMutation": "27184292767848867",
        "PolarisCommentActionsUnlikeMutation": "27318337671093716",
        "PolarisCommentActionsDeleteMutation": "28973546118903529",
        "usePolarisCommentCreateMutation": "39617891021192323",
    ]

    /// Recorded: `input` {comment_id, actor_id, client_mutation_id}.
    func setCommentLiked(_ liked: Bool, comment id: String) async throws {
        let name = liked ? "PolarisCommentActionsLikeMutation" : "PolarisCommentActionsUnlikeMutation"
        await prepare()
        _ = try await graphQL(name, variables: ["input": mutationInput(["comment_id": .string(id)])], docId: doc(name))
    }

    /// Deletes one of your comments, as recorded: `input` {comment_id, media_id, actor_id,
    /// client_mutation_id}.
    func deleteComment(_ id: String, media pk: String) async throws {
        let name = "PolarisCommentActionsDeleteMutation"
        await prepare()
        let r = try await graphQL(name, variables: ["input": mutationInput(["comment_id": .string(id), "media_id": .string(pk)])],
                                  docId: doc(name))
        if let type = r["xig_comment_delete"]["__typename"].string, !type.contains("Success") {
            throw IGError.api("Instagram didn't delete the comment.")
        }
    }

    /// Posts a comment, or a reply when `replyTo` is a comment id. Returns the new comment.
    /// Recorded for a top-level comment: `data` {comment_text, media_id} and the Relay
    /// connection the web app adds it to; for a reply, `replied_to_comment_fbid` (a string) and no
    /// connection.
    func postComment(_ text: String, media pk: String, replyTo: String? = nil) async throws -> IGComment? {
        let name = "usePolarisCommentCreateMutation"
        var data: [String: JSON] = ["comment_text": .string(text), "media_id": .string(pk)]
        if let replyTo { data["replied_to_comment_fbid"] = .string(replyTo) }
        let connection = #"client:XIGPolarisImageMedia:POLARIS_\#(pk):__PolarisPostComments__comments_connection_connection(input:{"sort_order":"popular"})"#
        await prepare()
        let result = try await graphQL(name, variables: [
            "data": .object(data), "root_connections": .array(replyTo == nil ? [.string(connection)] : []),
        ], docId: doc(name))
        let made = result["xig_comment_create"]
        return Parser.comment(made["comment"]) ?? Parser.comment(made)
    }

    /// Tells Instagram you watched a story item (you then appear in its viewers). Exactly what
    /// instagram.com sends when a story is shown (recorded 2026-11-12): `PolarisStoriesV3SeenMutation`
    /// with the ids as strings and the two times as numbers (Unix seconds; recorded 4 times).
    /// `reelId` is the owner's id, or "highlight:…".
    func markStorySeen(reelId: String, media: Media) async throws {
        let name = "PolarisStoriesV3SeenMutation"
        await prepare()
        let owner = media.user?.id ?? (reelId.hasPrefix("highlight:") ? "" : reelId)
        let result = try await graphQL(name, variables: [
            "reelId": .string(reelId), "reelMediaId": .string(media.pk), "reelMediaOwnerId": .string(owner),
            "reelMediaTakenAt": .integer(Int64(media.takenAt?.timeIntervalSince1970 ?? 0)),
            "viewSeenAt": .integer(Int64(Date.now.timeIntervalSince1970)),
        ], docId: knownOperations()[name] ?? "26234228992942885")
        guard !result["xdt_mark_story_reel_seen"].isNull else { throw IGError.badResponse }
    }

    /// Likes or unlikes a story item, exactly as instagram.com does (both recorded 2026-11-12):
    /// `usePolarisStoriesV4LikeMutation{Like,Unlike}Mutation` with your actor id, the mutation
    /// counter and the bare media pk.
    func setStoryLiked(_ liked: Bool, media: Media) async throws {
        await prepare()
        let name = liked ? "usePolarisStoriesV4LikeMutationLikeMutation" : "usePolarisStoriesV4LikeMutationUnlikeMutation"
        let r = try await graphQL(name, variables: ["input": mutationInput(["media_id": .string(media.pk)])],
                                  docId: knownOperations()[name] ?? (liked ? "26938887309082050" : "26510485515280697"))
        if liked, r["xig_send_story_like"].isNull { throw IGError.badResponse }
    }

    /// Who viewed one of your stories, a page at a time: whether each liked it and any reply.
    /// What instagram.com calls when you open a story's viewer list (a POST that only reads).
    func storyViewers(mediaPk: String, cursor: String? = nil) async throws -> (viewers: [StoryViewerEntry], total: Int?, next: String?) {
        var form = ["include_blacklist_sample": "true"]
        if let cursor { form["max_id"] = cursor }
        let json = try await rest(.post, "/api/v1/media/\(mediaPk)/list_reel_media_viewer/", form: form)
        let viewers: [StoryViewerEntry] = json["viewers"].array.compactMap { v in
            guard let user = Parser.user(v["user"]) else { return nil }
            return StoryViewerEntry(user: user, liked: v["has_liked"].bool ?? false,
                                    reply: v["reply_text"].string.flatMap { $0.isEmpty ? nil : $0 })
        }
        return (viewers, json["total_viewer_count"].int ?? json["user_count"].int, json["next_max_id"].string)
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


/// One person who viewed your story.
nonisolated struct StoryViewerEntry: Identifiable, Hashable, Sendable {
    var id: String { user.id }
    var user: User
    var liked: Bool
    var reply: String?
}
