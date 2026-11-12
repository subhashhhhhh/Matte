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
        guard let id = idString(j["pk"]) ?? idString(j["id"]), let text = j["text"].string else { return nil }
        return IGComment(id: id, user: user(j["user"]), text: text,
                         createdAt: j["created_at"].double.map { Date(timeIntervalSince1970: $0) },
                         likeCount: j["comment_like_count"].int ?? 0,
                         replyCount: j["child_comment_count"].int ?? 0)
    }
}
