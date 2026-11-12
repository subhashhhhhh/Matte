import Foundation

/// One post or reel by id, and its comments (REST endpoints that accept the web session).
extension IGClient {
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
