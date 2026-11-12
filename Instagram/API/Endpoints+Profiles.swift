import Foundation

/// Profile tabs, highlights, follower lists, saved posts, hashtags and following, with the
/// variables the web app sends (captured 2026-11-12). Doc ids: `discoverDocIds`.
extension IGClient {
    private func profileQuery(_ name: String, variables: JSON) async throws -> JSON {
        await prepare()
        return try await graphQL(name, variables: variables, docId: knownOperations()[name] ?? Self.discoverDocIds[name])
    }

    // MARK: Tabs

    /// Reels tab. Items carry a cover and counts but no video: the opened reel is fetched by id.
    func profileReels(userId: String, after cursor: String? = nil) async throws -> Page<Media> {
        var vars: [String: JSON] = [
            "data": ["include_feed_video": true, "page_size": 12, "target_user_id": .string(userId)],
            "user_id": .string(userId),
            "__relay_internal__pv__PolarisShortDramaEnabledrelayprovider": true,
        ]
        if let cursor { vars["after"] = .string(cursor); vars["first"] = 12 }
        let data = try await profileQuery("PolarisProfileReelsTabContentQuery", variables: .object(vars))
        defer { MemoryRelief.soon() }
        return Parser.mediaConnection(data, root: "clips_connection")
    }

    /// Posts other people tagged this account in.
    func profileTagged(userId: String, after cursor: String? = nil) async throws -> Page<Media> {
        var vars: [String: JSON] = [
            "count": 12, "user_id": .string(userId),
            "__relay_internal__pv__PolarisShortDramaEnabledrelayprovider": true,
            "__relay_internal__pv__PolarisSEOIsCrawlerrelayprovider": false,
        ]
        if let cursor { vars["after"] = .string(cursor); vars["first"] = 12 }
        let data = try await profileQuery("PolarisProfileTaggedTabContentQuery", variables: .object(vars))
        defer { MemoryRelief.soon() }
        return Parser.mediaConnection(data, root: "xdt_api__v1__usertags__user_id__feed_connection", nodeIsMedia: true)
    }

    /// Reposts tab, as recorded: the first page by `user_id`, later pages by `id` + `max_id`.
    func profileReposts(userId: String, after cursor: String? = nil) async throws -> Page<Media> {
        var vars: [String: JSON] = [
            "__relay_internal__pv__PolarisShortDramaEnabledrelayprovider": true,
            "__relay_internal__pv__PolarisSEOIsCrawlerrelayprovider": false,
        ]
        let name: String
        if let cursor {
            name = "PolarisProfileRepostsTabContentRefetchQuery"
            vars["max_id"] = .string(cursor)
            vars["id"] = .string(userId)
        } else {
            name = "PolarisProfileRepostsTabContentQuery"
            vars["user_id"] = .string(userId)
        }
        let data = try await profileQuery(name, variables: .object(vars))
        defer { MemoryRelief.soon() }
        let timeline = data["fetch__XDTUserDict"]["user_reposts_timeline"]
        let items = timeline["repost_grid_items"].array.compactMap { Parser.media($0["media"]) }
        let next = timeline["repost_next_max_id"].string
        return Page(items: items, cursor: next, hasMore: timeline["repost_more_available"].bool == true && next != nil)
    }

    // MARK: Highlights

    func highlights(userId: String) async throws -> [Highlight] {
        let data = try await profileQuery("PolarisProfileStoryHighlightsTrayContentQuery", variables: ["user_id": .string(userId)])
        return data["highlights"]["edges"].array.compactMap { edge in
            let n = edge["node"]
            guard let id = n["id"].string else { return nil }
            return Highlight(id: id, title: n["title"].string ?? "",
                             cover: n["cover_media"]["cropped_image_version"]["url"].string.flatMap(URL.init(string:)))
        }
    }

    // MARK: Followers and following

    /// One page of someone's followers or the accounts they follow. Instagram caps what it
    /// shows of other people's lists (`hasMore` turns false early).
    func followList(userId: String, followers: Bool, maxId: String? = nil) async throws -> Page<User> {
        var query = ["count": "12"]
        if followers { query["search_surface"] = "follow_list_page" }
        if let maxId { query["max_id"] = maxId }
        let json = try await rest(.get, "/api/v1/friendships/\(userId)/\(followers ? "followers" : "following")/", query: query)
        let users = json["users"].array.compactMap(Parser.user)
        let next = Parser.idString(json["next_max_id"])
        return Page(items: users, cursor: next, hasMore: next != nil && !users.isEmpty)
    }

    /// Your relationship to each of these accounts (read-only; the web app asks the same).
    func friendships(_ userIds: [String]) async throws -> [String: Friendship] {
        guard !userIds.isEmpty else { return [:] }
        await prepare()
        // The web app's REST POSTs carry the page's form tokens.
        var form = ["user_ids": userIds.joined(separator: ",")]
        if let dtsg = page.dtsg { form["fb_dtsg"] = dtsg }
        if let jazoest = page.jazoest { form["jazoest"] = jazoest }
        let json = try await rest(.post, "/api/v1/friendships/show_many/", form: form)
        var out: [String: Friendship] = [:]
        for (id, f) in json["friendship_statuses"].object ?? [:] {
            out[id] = Friendship(following: f["following"].bool ?? false, followedBy: f["followed_by"].bool ?? false,
                                 requested: f["outgoing_request"].bool ?? false)
        }
        return out
    }

    /// Follows or unfollows (unfollowing also withdraws a pending request). Returns the new
    /// relationship as Instagram reports it.
    func setFollowing(_ follow: Bool, userId: String) async throws -> Friendship {
        let name = follow ? "usePolarisFollowMutation" : "usePolarisUnfollowMutation"
        let data = try await profileQuery(name, variables: [
            "target_user_id": .string(userId), "container_module": "profile", "nav_chain": "",
        ])
        let f = data[follow ? "xdt_create_friendship" : "xdt_destroy_friendship"]["friendship_status"]
        guard !f.isNull else { throw IGError.api(follow ? "Instagram didn't accept the follow." : "Instagram didn't accept the unfollow.") }
        return Friendship(following: f["following"].bool ?? false, followedBy: f["followed_by"].bool ?? false,
                          requested: f["outgoing_request"].bool ?? false)
    }

    // MARK: Saved

    /// Your saved posts, all of them, newest first.
    func savedPosts(maxId: String? = nil) async throws -> Page<Media> {
        var query: [String: String] = [:]
        if let maxId { query["max_id"] = maxId }
        let json = try await rest(.get, "/api/v1/feed/saved/posts/", query: query)
        defer { MemoryRelief.soon() }
        return Self.savedPage(json)
    }

    /// One of your collections.
    func collectionPosts(id: String, maxId: String? = nil) async throws -> Page<Media> {
        var query: [String: String] = [:]
        if let maxId { query["max_id"] = maxId }
        let json = try await rest(.get, "/api/v1/feed/collection/\(id)/posts/", query: query)
        defer { MemoryRelief.soon() }
        return Self.savedPage(json)
    }

    private nonisolated static func savedPage(_ json: JSON) -> Page<Media> {
        let items = json["items"].array.compactMap { Parser.media($0["media"]) }
        let next = Parser.idString(json["next_max_id"])
        return Page(items: items, cursor: next, hasMore: (json["more_available"].bool ?? false) && next != nil)
    }

    /// Your collections (named ones; "All posts" is `savedPosts`).
    func savedCollections() async throws -> [SavedCollection] {
        let data = try await profileQuery("PolarisProfileSavedTabContentQuery", variables: [
            "collection_types": ["ALL_MEDIA_AUTO_COLLECTION", "PLAYLIST_AUTO_COLLECTION", "MEDIA", "AUDIO_AUTO_COLLECTION"],
            "first": 24,
        ])
        let edges = data.first("collections_unified_with_auto_collections")?["edges"].array ?? []
        return edges.compactMap { edge in
            let n = edge["node"]
            guard let id = Parser.idString(n["collection_id"]), let name = n["collection_name"].string else { return nil }
            let covers = n["cover_media_list"].array.compactMap(Parser.media)
            let cover = Parser.media(n["cover_media"]) ?? covers.first
            return SavedCollection(id: id, name: name, count: n["collection_media_count"].int,
                                   cover: cover?.image(minWidth: 300),
                                   isAll: n["__typename"].string == "IGAllMediaAutoCollection" || id == "ALL_MEDIA_AUTO_COLLECTION",
                                   isMedia: n["__typename"].string.map { $0.contains("Audio") || $0.contains("Playlist") } != true)
        }
    }

    // MARK: Hashtags

    /// Top posts for a hashtag (the web app's keyword results for `#tag`).
    func hashtagPosts(_ tag: String, sessionId: String, after cursor: String? = nil) async throws -> Page<Media> {
        var vars: [String: JSON] = ["query": .string("#" + tag), "search_session_id": .string(sessionId), "serp_session_id": .string(sessionId)]
        if let cursor { vars["after"] = .string(cursor); vars["first"] = 12 }
        let data = try await profileQuery("PolarisKeywordSearchExplorePageRelayQuery", variables: .object(vars))
        defer { MemoryRelief.soon() }
        let conn = data["xdt_fbsearch__top_serp_graphql"]
        var seen = Set<String>()
        var items: [Media] = []
        for edge in conn["edges"].array {
            for m in edge["node"]["items"].array.compactMap(Parser.media) where seen.insert(m.pk).inserted { items.append(m) }
        }
        let info = conn["page_info"]
        return Page(items: items, cursor: info["end_cursor"].string, hasMore: info["has_next_page"].bool ?? false)
    }

    /// The hashtag's post count, from search (nil if search doesn't list it).
    func hashtagInfo(_ tag: String, sessionId: String) async throws -> Hashtag? {
        for q in ["#" + tag, tag] {
            let found = try await search(q, sessionId: sessionId)
            if let h = found.hashtags.first(where: { $0.name.caseInsensitiveCompare(tag) == .orderedSame }) { return h }
        }
        return nil
    }
}
