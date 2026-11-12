import Foundation

/// Your own account: editing your profile and your story archive. Each call is what
/// instagram.com sent in the user's recording (2026-11-12).
extension IGClient {
    /// The web app's page parameters and headers on its older "ajax" GETs (recorded on the
    /// archive): its route, the async-get token `fb_dtsg_ag` and the page's spin values.
    func ajaxGet(_ path: String, route: String, query extra: [String: String] = [:]) async throws -> JSON {
        await prepare()
        var q = page.commonForm(counter: String(Int.random(in: 40...900), radix: 36), userId: await session.userId)
            .filter { !["fb_dtsg", "jazoest", "lsd", "av"].contains($0.key) }
        q["__comet_req"] = "7"
        q["__crn"] = route
        if let r = page.spinR { q["__spin_r"] = r }
        if let b = page.spinB { q["__spin_b"] = b }
        if let t = page.spinT { q["__spin_t"] = t }
        if let ag = page.asyncGetToken {
            q["fb_dtsg_ag"] = ag
            q["jazoest"] = "2" + String(ag.unicodeScalars.reduce(0) { $0 + Int($1.value) })
        }
        q.merge(extra) { _, new in new }
        var headers = ["X-IG-D": "www"]
        if let lsd = page.lsd { headers["X-FB-LSD"] = lsd }
        if let nonce = page.entryNonce { headers["X-FB-Entry-Nonce"] = nonce }
        return try await rest(.get, path, query: q, headers: headers)
    }

    // MARK: Profile

    /// What the edit-profile page starts from.
    func editableProfile() async throws -> EditableProfile {
        let json = try await rest(.get, "/api/v1/accounts/edit/web_form_data/")
        let f = json["form_data"]
        return EditableProfile(name: f["first_name"].string ?? "", username: f["username"].string ?? "",
                               bio: f["biography"].string ?? "", link: f["external_url"].string ?? "",
                               suggestAccount: f["chaining_enabled"].bool ?? true)
    }

    /// Saves name, username, bio and link (recorded: `web/accounts/edit` with the form tokens).
    func saveProfile(_ p: EditableProfile) async throws {
        var form = formTokens()
        form["first_name"] = p.name
        form["username"] = p.username
        form["biography"] = p.bio
        form["external_url"] = p.link
        // A web checkbox: "on" when ticked (recorded), left out when not.
        if p.suggestAccount { form["chaining_enabled"] = "on" }
        let json = try await rest(.post, "/api/v1/web/accounts/edit/", form: form)
        if json["status"].string != "ok" { throw IGError.api(json["message"].string ?? "Couldn't save your profile") }
    }

    // MARK: Archive

    /// Days with archived stories, newest first, a page at a time.
    func archiveDays(after cursor: String? = nil) async throws -> (days: [ArchiveDay], next: String?) {
        var extra = ["timezone_offset": String(TimeZone.current.secondsFromGMT())]
        if let cursor { extra["max_id"] = cursor }
        let json = try await ajaxGet("/api/v1/archive/reel/day_shells/", route: "comet.igweb.PolarisArchivePageRoute", query: extra)
        let p = json["payload"].isNull ? json : json["payload"]
        let days: [ArchiveDay] = p["items"].array.compactMap { d in
            guard let id = d["id"].string else { return nil }
            return ArchiveDay(id: id, date: d["timestamp"].double.map { Date(timeIntervalSince1970: $0) },
                              count: d["media_count"].int ?? 0)
        }
        let more = p["more_available"].bool ?? false
        return (days, more ? Parser.idString(p["max_id"]) : nil)
    }

    /// The stories of some archive days (as the web app loads them: several ids at once).
    func archiveReels(_ ids: [String]) async throws -> [String: [Media]] {
        var form = formTokens()
        form["reel_ids"] = String(data: (try? JSONSerialization.data(withJSONObject: ids)) ?? Data("[]".utf8), encoding: .utf8)
        let json = try await rest(.post, "/api/v1/feed/reels_media/", form: form)
        var out: [String: [Media]] = [:]
        for id in ids { out[id] = json["reels"][id]["items"].array.compactMap(Parser.media) }
        MemoryRelief.soon()
        return out
    }
}

nonisolated struct EditableProfile: Equatable, Sendable {
    var name: String
    var username: String
    var bio: String
    var link: String
    var suggestAccount: Bool
}

nonisolated struct ArchiveDay: Identifiable, Hashable, Sendable {
    var id: String
    var date: Date?
    var count: Int
}
