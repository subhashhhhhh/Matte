import Foundation

/// Search, profiles and Explore, with the variables the web app sends (captured 2026-11-12).
extension IGClient {
    nonisolated static let discoverDocIds: [String: String] = [
        "PolarisAPITopsearchQuery": "40560838120170065",
        "PolarisProfilePageContentQuery": "40158838120366999",
        "PolarisProfilePostsQuery": "29114630661562380",
        // Lazy chunks (profile tabs, highlights, saved, hashtags, follow), read 2026-11-12.
        "PolarisProfileStoryHighlightsTrayContentQuery": "26970053832668570",
        "PolarisProfileReelsTabContentQuery": "28280418711631396",
        "PolarisProfileTaggedTabContentQuery": "28196060226733657",
        "PolarisProfileSavedTabContentQuery": "27584326974521636",
        "PolarisKeywordSearchExplorePageRelayQuery": "37324993597144881",
        "usePolarisFollowMutation": "26508036048874888",
        "usePolarisUnfollowMutation": "27789106940691111",
    ]

    private func discoverQuery(_ name: String, variables: JSON) async throws -> JSON {
        await prepare()
        return try await graphQL(name, variables: variables, docId: knownOperations()[name] ?? Self.discoverDocIds[name])
    }

    func search(_ query: String, sessionId: String) async throws -> SearchResults {
        let data = try await discoverQuery("PolarisAPITopsearchQuery", variables: [
            "data": ["context": "blended", "include_reel": "true", "query": .string(query), "rank_token": "",
                     "search_session_id": .string(sessionId), "search_surface": "web_top_search"],
        ])
        let root = data["xdt_api__v1__fbsearch__topsearch_connection"]
        var out = SearchResults()
        out.users = root["users"].array.compactMap { Parser.user($0["user"]) }
        out.hashtags = root["hashtags"].array.compactMap { h in
            let tag = h["hashtag"]
            guard let name = tag["name"].string else { return nil }
            return Hashtag(name: name, mediaCount: tag["media_count"].int)
        }
        return out
    }

    func profile(id: String) async throws -> Profile {
        let data = try await discoverQuery("PolarisProfilePageContentQuery", variables: [
            "enable_integrity_filters": true, "id": .string(id),
            "__relay_internal__pv__PolarisCannesGuardianExperienceEnabledrelayprovider": true,
            "__relay_internal__pv__PolarisCASB976ProfileEnabledrelayprovider": false,
            "__relay_internal__pv__PolarisProfileInformTreatmentBannerEnabledrelayprovider": false,
            "__relay_internal__pv__PolarisWebSchoolsEnabledrelayprovider": false,
            "__relay_internal__pv__PolarisProfileRingsGradientEnabledrelayprovider": true,
            "__relay_internal__pv__PolarisRepostsConsumptionEnabledrelayprovider": true,
            "__relay_internal__pv__PolarisShortDramaEnabledrelayprovider": true,
        ])
        let u = data["user"]
        guard let user = Parser.user(u) else { throw IGError.badResponse }
        var p = Profile(user: user)
        p.biography = u["biography"].string.flatMap { $0.isEmpty ? nil : $0 }
        p.category = u["category"].string.flatMap { $0.isEmpty ? nil : $0 }
        p.externalURL = (u["bio_links"][0]["url"].string ?? u["external_url"].string).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        p.postCount = u["media_count"].int
        p.followerCount = u["follower_count"].int
        p.followingCount = u["following_count"].int
        p.mutualFollowers = u["mutual_followers_count"].int
        p.isPrivate = u["is_private"].bool ?? false
        p.following = u["friendship_status"]["following"].bool ?? false
        p.followedBy = u["friendship_status"]["followed_by"].bool ?? false
        p.requested = u["friendship_status"]["outgoing_request"].bool ?? false
        p.hdAvatar = u["hd_profile_pic_url_info"]["url"].string.flatMap(URL.init(string:))
        return p
    }

    func profilePosts(username: String, after cursor: String? = nil) async throws -> Page<Media> {
        let data = try await discoverQuery("PolarisProfilePostsQuery", variables: [
            "after": cursor.map(JSON.string) ?? .null, "before": nil, "first": 12, "last": nil,
            "data": ["count": 12, "include_reel_media_seen_timestamp": true, "include_relationship_info": true,
                     "latest_besties_reel_media": true, "latest_reel_media": true],
            "username": .string(username),
            "__relay_internal__pv__PolarisMultiCaptionCarouselEnabledrelayprovider": false,
            "__relay_internal__pv__PolarisShortDramaEnabledrelayprovider": true,
            "__relay_internal__pv__PolarisSEOIsCrawlerrelayprovider": false,
            "__relay_internal__pv__PolarisThreadsStyleCommentsEnabledrelayprovider": false,
            "__relay_internal__pv__PolarisReelsRecoDebugOverlayEnabledrelayprovider": false,
        ])
        defer { MemoryRelief.soon() }
        return Parser.mediaConnection(data, root: "xdt_api__v1__feed__user_timeline_graphql_connection", nodeIsMedia: true)
    }

    /// The Explore grid, a page at a time. Pass the previous page's `cursor` (`max_id`) and the
    /// paging token it returned.
    func explore(maxId: String? = nil, pagingToken: String? = nil) async throws -> (items: [Media], next: String?, token: String?, more: Bool) {
        var query = ["include_fixed_destinations": "true", "is_nonpersonalized_explore": "false",
                     "is_prefetch": "false"]
        if let maxId { query["max_id"] = maxId }
        if let pagingToken { query["session_paging_token"] = pagingToken }
        let json = try await rest(.get, "/api/v1/discover/web/explore_grid/", query: query)
        var items: [Media] = []
        for section in json["sectional_items"].array {
            for cell in section["layout_content"]["medias"].array {
                if let m = Parser.media(cell["media"]) { items.append(m) }
                for clip in cell["clips"]["items"].array { if let m = Parser.media(clip["media"]) { items.append(m) } }
            }
            for cell in section["layout_content"]["fill_items"].array { if let m = Parser.media(cell["media"]) { items.append(m) } }
            if let m = Parser.media(section["layout_content"]["one_by_two_item"]["clips"]["items"][0]["media"]) { items.append(m) }
        }
        defer { MemoryRelief.soon() }
        var seen = Set<String>()
        items = items.filter { seen.insert($0.pk).inserted }
        return (items, json["next_max_id"].string, json["session_paging_token"].string, json["more_available"].bool ?? false)
    }
}
