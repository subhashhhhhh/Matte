import Foundation

/// A post Instagram holds to publish later (professional accounts). Instagram publishes it at
/// `publishAt` itself, whether or not Matte is running.
nonisolated struct ScheduledPost: Codable, Hashable, Sendable, Identifiable {
    enum Kind: String, Codable, Sendable { case photo, carousel, reel, video }

    /// The scheduled item's id (what cancelling takes), not the media's.
    var id: String
    var publishAt: Date
    var caption: String
    var kind: Kind
    /// The (first) image, for the calendar.
    var thumbnail: URL?
    /// The media's id (`<pk>_<owner>`).
    var mediaId: String?
    var carouselCount: Int = 0
}

extension IGClient {
    /// Recorded on instagram.com (2026-11-13): scheduling a photo, the calendar of scheduled
    /// posts, and cancelling one from it.
    nonisolated static let scheduleDocIds: [String: String] = [
        "PolarisScheduledContentCalendarQuery": "28886777017638780",
        "PolarisScheduledContentMutationsDeleteMutation": "26836322409389162",
    ]

    /// How far ahead Instagram lets you schedule, and the soonest Matte offers (Instagram's own
    /// apps say 75 days and need a few minutes' notice).
    nonisolated static let scheduleWindow: (min: TimeInterval, max: TimeInterval) = (15 * 60, 75 * 86_400)

    /// The configure fields that make a publish a scheduled one (recorded: `async_publish` 1,
    /// `content_scheduling_metadata` with the time in Unix seconds, `publish_mode` "scheduled").
    nonisolated static func scheduleFields(_ date: Date) -> [(String, OrderedJSON)] {
        let seconds = String(Int64(date.timeIntervalSince1970.rounded(.down)))
        return [("async_publish", .string("1")),
                ("content_scheduling_metadata", .string(#"{"scheduled_publish_time":""# + seconds + #""}"#)),
                ("publish_mode", .string("scheduled"))]
    }

    /// Everything the account has scheduled, soonest first.
    func scheduledPosts() async throws -> [ScheduledPost] {
        let name = "PolarisScheduledContentCalendarQuery"
        let data = try await graphQL(name, variables: .object([:]), docId: knownOperations()[name] ?? Self.scheduleDocIds[name])
        let user = data["viewer"]["xdt_user"]
        guard !user.isNull else { throw IGError.api("Instagram didn't return your scheduled posts.") }
        return Self.parseScheduled(user["all_scheduled_ig_content"]).sorted { $0.publishAt < $1.publishAt }
    }

    nonisolated static func parseScheduled(_ list: JSON) -> [ScheduledPost] {
        list.array.prefix(500).compactMap { item -> ScheduledPost? in
            guard let id = item["id"].string, !id.isEmpty, let time = item["scheduled_publish_time"].int else { return nil }
            let media = item["media"]
            let children = item["carousel_children"].array
            let product = media["product_type"].string ?? ""
            let kind: ScheduledPost.Kind = !children.isEmpty || product == "carousel_container" ? .carousel
                : product == "clips" ? .reel
                : (media["media_type"].int == 2 ? .video : .photo)
            let imageSource = children.first.map { $0["media"].isNull ? $0 : $0["media"] } ?? media
            let thumb = imageSource["image_versions2"]["candidates"].array.first?["url"].string
                ?? media["image_versions2"]["candidates"].array.first?["url"].string
            return ScheduledPost(id: id, publishAt: Date(timeIntervalSince1970: TimeInterval(time)),
                                 caption: item["caption_text"].string ?? "", kind: kind,
                                 thumbnail: thumb.flatMap(URL.init(string:)), mediaId: media["id"].string,
                                 carouselCount: children.count)
        }
    }

    /// Cancels a scheduled post (recorded: the scheduled item's id, in the usual mutation input).
    func cancelScheduled(id: String) async throws {
        await prepare()
        let name = "PolarisScheduledContentMutationsDeleteMutation"
        let doc = knownOperations()[name] ?? Self.scheduleDocIds[name]
        let data = try await graphQL(name, variables: .object(["input": mutationInput(["scheduled_content_id": .string(id)])]), docId: doc)
        guard data["xig_delete_scheduled_ig_content"]["deleted_id"].string == id else {
            throw IGError.api("Instagram didn't cancel the scheduled post.")
        }
    }
}
