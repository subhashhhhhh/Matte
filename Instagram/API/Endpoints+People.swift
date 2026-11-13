import Foundation

/// Who liked a post or a comment, and your recent searches, as instagram.com asks for them
/// (recorded 2026-11-13).
extension IGClient {
    nonisolated static let peopleDocIds: [String: String] = [
        "PolarisSearchNullStateQuery": "38466302779627407",
        "PolarisSearchNullStateSectionDismissItemMutation": "28901463709460248",
    ]
    /// The comment likers query, by doc id (the web app sends it as a GET to /graphql/query/).
    nonisolated static let commentLikersDocId = "17953756669066153"

    /// Everyone who liked a post, in one answer (`media/<pk>/likers/`; the web app doesn't page it).
    func likers(pk: String) async throws -> [User] {
        let json = try await rest(.get, "media/\(pk)/likers/")
        return json["users"].array.compactMap(Parser.user)
    }

    /// Who liked a comment, 48 at a time.
    func commentLikers(commentId: String, after cursor: String?) async throws -> Page<User> {
        var vars: [String: JSON] = ["comment_id": .string(commentId), "first": 48]
        if let cursor { vars["after"] = .string(cursor) }
        let json = try await rest(.get, "/graphql/query/", query: ["doc_id": Self.commentLikersDocId,
                                                                   "variables": String(decoding: (try? JSON.object(vars).data()) ?? Data("{}".utf8), as: UTF8.self)])
        let edge = json["data"]["comment"]["edge_liked_by"]
        let users = edge["edges"].array.compactMap { Parser.user($0["node"]) }
        let info = edge["page_info"]
        let next = info["end_cursor"].string.flatMap { $0.isEmpty ? nil : $0 }
        return Page(items: users, cursor: next, hasMore: info["has_next_page"].bool == true && next != nil)
    }

    /// Your recent searches (what the search box shows before you type).
    func recentSearches() async throws -> [RecentSearch] {
        await prepare()
        let name = "PolarisSearchNullStateQuery"
        let data = try await graphQL(name, variables: [:], docId: knownOperations()[name] ?? Self.peopleDocIds[name])
        return data["xig_recent_searches"]["recent_searches"].array.compactMap { e in
            if let u = Parser.user(e["user"]) { return .user(u) }
            if let tag = e["hashtag"]["name"].string { return .hashtag(Hashtag(name: tag, mediaCount: e["hashtag"]["media_count"].int)) }
            if let word = e["keyword"]["name"].string, !word.isEmpty { return .keyword(word) }
            return nil
        }
    }

    /// Removes a typed search from your recent searches (the only kind recorded so far).
    func removeRecentKeyword(_ word: String) async throws {
        await prepare()
        let name = "PolarisSearchNullStateSectionDismissItemMutation"
        _ = try await graphQL(name, variables: ["input": mutationInput([
            "hashtag": [], "keyword_names": .string(String(decoding: (try? JSON.array([.string(word)]).data()) ?? Data("[]".utf8), as: UTF8.self)), "place": [],
            "section": "recent", "user": [],
        ])], docId: knownOperations()[name] ?? Self.peopleDocIds[name])
    }
}

/// One of your recent searches.
nonisolated enum RecentSearch: Hashable, Sendable, Identifiable {
    case user(User), hashtag(Hashtag), keyword(String)

    var id: String {
        switch self {
        case .user(let u): "u" + u.id
        case .hashtag(let h): "h" + h.name
        case .keyword(let k): "k" + k
        }
    }
}
