import Foundation

/// Every call the app makes, built from the web app's own requests (captured with
/// `-IGCapture`). Relay "provided variables" (`__relay_internal__pv__…`) must be sent with the
/// values the web app uses, or the query is rejected.
extension IGClient {
    // MARK: Feed

    /// The home feed: `.forYou` is Instagram's ranked feed; `.following` is everyone you follow,
    /// newest first, without suggestions; `.favorites` only your favourites. The web app picks
    /// the feed with `data.pagination_source` (the top-level `variant` changes nothing).
    func homeFeed(after cursor: String? = nil, source: FeedSource = .forYou) async throws -> Page<Media> {
        let deviceId = await session.cookie("ig_did") ?? UUID().uuidString
        var feedData: [String: JSON] = ["device_id": .string(deviceId), "is_async_ads_double_request": "0",
                                         "is_async_ads_in_headload_enabled": "0", "is_async_ads_rti": "0", "rti_delivery_backend": "0"]
        if source != .forYou { feedData["pagination_source"] = .string(source.rawValue) }
        let vars: JSON = [
            "after": cursor.map(JSON.string) ?? .null, "before": nil, "first": 12, "last": nil,
            "variant": source == .forYou ? "home" : .string(source.rawValue),
            "data": .object(feedData),
            "__relay_internal__pv__PolarisShortDramaEnabledrelayprovider": true,
            "__relay_internal__pv__PolarisMultiCaptionCarouselEnabledrelayprovider": false,
            "__relay_internal__pv__PolarisThreadsStyleCommentsEnabledrelayprovider": false,
            "__relay_internal__pv__PolarisReelsRecoDebugOverlayEnabledrelayprovider": false,
            "__relay_internal__pv__PolarisAdDebugToolEnabledrelayprovider": false,
            "__relay_internal__pv__PolarisSuggestedUserFeedUnitCardsEnabledrelayprovider": true,
        ]
        let data = try await graphQL("PolarisFeedTimelineRootV2Query", variables: vars)
        defer { MemoryRelief.soon() }
        return Parser.mediaConnection(data, root: "xdt_api__v1__feed__timeline__connection")
    }

    // MARK: Reels

    func reels(after cursor: String? = nil) async throws -> Page<Media> {
        let vars: JSON = [
            "data": ["container_module": "clips_tab_desktop_page"],
            "first": 8, "after": cursor.map(JSON.string) ?? .null, "before": nil, "last": nil,
            "__relay_internal__pv__PolarisReelsRecoDebugOverlayEnabledrelayprovider": false,
            "__relay_internal__pv__PolarisShortDramaEnabledrelayprovider": true,
            "__relay_internal__pv__PolarisThreadsStyleCommentsEnabledrelayprovider": false,
        ]
        let name = cursor == nil ? "PolarisClipsHomeRootQuery" : "PolarisClipsTabRootPaginationQuery"
        let data = try await graphQL(name, variables: vars)
        defer { MemoryRelief.soon() }
        return Parser.mediaConnection(data, root: "xdt_api__v1__clips__home__connection_v2")
    }

    // MARK: Stories

    func storyTray() async throws -> [StoryReel] {
        let data = try await graphQL("PolarisStoriesV3TrayContainerQuery",
                                     variables: ["data": ["is_following_feed": false, "reason": "web_home"]])
        return Parser.storyTray(data)
    }

    /// The items of up to a few reels at once (the web app asks for the open one and the next two).
    func storyReels(ids: [String]) async throws -> [StoryReel] {
        let data = try await graphQL("PolarisStoriesV3ReelPageStandaloneQuery", variables: [
            "reel_ids_arr": .array(ids.map(JSON.string)), "is_highlight": false, "media_id": nil,
            "__relay_internal__pv__PolarisCommunityNoteStoriesLabelEnabledrelayprovider": false,
        ])
        defer { MemoryRelief.soon() }
        return Parser.storyReels(data)
    }

    // MARK: DMs

    /// The inbox's first page, and the sequence id the real-time socket resumes from.
    /// Loads the page config the DM variables are built from (device and messaging ids)
    /// before they're read: on a cold start the first call would otherwise send them empty.
    private func ensureDMConfig() async {
        await prepare()
        if page.dmDeviceId == nil || page.messagingId == nil { await scanPage("/direct/inbox/") }
    }

    func inbox() async throws -> (threads: [DMThread], cursor: String?, hasMore: Bool, seqId: String?) {
        await ensureDMConfig()
        let data = try await dmQuery("PolarisDirectInboxQuery", variables: [
            "device_id_for_iris_subscription": .string(page.dmDeviceId ?? ""),
            "__relay_internal__pv__IGDIsProfessionalAccountGKrelayprovider": false,
            "__relay_internal__pv__IGDPinnedThreadsRenderEnabledGKrelayprovider": true,
            "__relay_internal__pv__IGDMaxUnreadMessagesCountrelayprovider": 5,
            "__relay_internal__pv__IGDThreadListActionsEnabledGKrelayprovider": true,
        ])
        let box = Parser.inbox(data)
        let seq = data.first("iris_inactive_subscription_uq_seq_id")?.string
        return (box.threads, box.cursor, box.hasMore, seq)
    }

    func olderThreads(cursor: String) async throws -> (threads: [DMThread], cursor: String?, hasMore: Bool) {
        await ensureDMConfig()
        let data = try await dmQuery("IGDThreadListOffMsysPaginationQuery", variables: [
            "count": 15, "cursor": .string(cursor), "folder": "INBOX", "newer_than_timestamp_ms": nil,
            "id": .string(page.messagingId ?? ""),
            "__relay_internal__pv__IGDPinnedThreadsRenderEnabledGKrelayprovider": true,
            "__relay_internal__pv__IGDMaxUnreadMessagesCountrelayprovider": 5,
            "__relay_internal__pv__PolarisAIGMAccountLabelEnabledrelayprovider": false,
            "__relay_internal__pv__IGDThreadListActionsEnabledGKrelayprovider": true,
        ])
        return Parser.inbox(data)
    }

    /// A thread and its newest messages (newest first).
    func thread(_ id: String) async throws -> (thread: DMThread?, messages: Page<DMMessage>) {
        let data = try await dmQuery("IGDThreadDetailQuery", variables: [
            "min_uq_seq_id": nil, "thread_fbid": .string(id),
            "__relay_internal__pv__IGDEnableOffMsysChatThemesQErelayprovider": false,
            "__relay_internal__pv__IGDInitialMessagePageCountrelayprovider": 20,
        ])
        let t = data.first("as_ig_direct_thread") ?? .null
        return (Parser.thread(t), Parser.messages(t["slide_messages"]))
    }

    /// Messages older than `cursor` (newest first).
    func olderMessages(thread id: String, cursor: String) async throws -> Page<DMMessage> {
        let data = try await dmQuery("IGDMessageListOffMsysQuery", variables: [
            "after": .string(cursor), "before": nil, "first": 20, "last": nil,
            "newer_than_message_id": nil, "older_than_message_id": nil, "id": .string(id),
            "__relay_internal__pv__IGDInitialMessagePageCountrelayprovider": 20,
        ])
        return Parser.messages(data.first("slide_messages") ?? .null)
    }

    /// Sends text (optionally as a reply). Returns the new message's id.
    @discardableResult
    func sendText(_ text: String, thread id: String, replyTo: String? = nil, offlineId: String) async throws -> String? {
        let data = try await dmQuery("IGDirectTextSendMutation", variables: [
            "ig_thread_igid": .string(id), "offline_threading_id": .string(offlineId), "recipient_igids": nil,
            "replied_to_client_context": nil, "replied_to_item_id": nil,
            "reply_to_message_id": replyTo.map(JSON.string) ?? .null, "sampled": nil,
            "text": ["sensitive_string_value": .string(text)],
            "mentions": nil, "mentioned_user_ids": nil, "commands": nil,
            "forwarded_from_thread_id": nil, "is_forwarded_from_own_message": nil,
            "send_attribution": "igd_web_chat_tab:in_thread",
        ])
        return data.first("message_id")?.string ?? data.first("id")?.string
    }

    /// Sends a post or reel into a chat, as the web app's share sheet does: reels by their id
    /// with the clip mutation, everything else as a media share.
    func share(_ media: Media, toThread id: String) async throws {
        let otid = OfflineThreadingId.next()
        let target: JSON = ["forwarded_from_thread_id": nil, "is_forwarded_from_own_message": nil,
                            "offline_threading_id": .string(otid), "recipient_users": nil, "thread_id": .string(id)]
        if media.productType == "clips" {
            _ = try await dmQuery("IGDirectReelShareMutation", variables: [
                "clip_share_params": ["inventory_source": nil, "send_attribution": "igd_web_share_sheet:reel",
                                      "social_context_share_type": nil, "text": nil, "tracking_token": nil],
                "data": target, "ig_media_igid": .string(media.pk), "otid": .string(otid),
            ])
        } else {
            _ = try await dmQuery("IGDirectMediaShareMutation", variables: [
                "data": ["media_id": .string(media.id)], "send_data": target,
            ])
        }
    }

    /// Adds `emoji` to a message, or removes `previous` when `emoji` is nil.
    func react(_ emoji: String?, previous: String? = nil, to messageId: String, thread id: String) async throws {
        let value = (emoji ?? previous ?? "").unicodeScalars.filter { $0.value != 0xFE0F }.map(String.init).joined()
        _ = try await dmQuery("IGDirectReactionSendMutation", variables: [
            "input": ["emoji": .string(value), "item_id": "", "message_id": .string(messageId),
                      "reaction_status": .string(emoji == nil ? "deleted" : "created"), "thread_id": .string(id)],
        ])
    }

    /// Marks a thread read up to `message`. Takes the thread's long id.
    func markRead(longThreadId: String, message: DMMessage) async throws {
        _ = try await dmQuery("useIGDMarkThreadAsReadMutation", variables: [
            "metadata": ["ig_thread_igid": .string(longThreadId)],
            "data": ["message_id": .string(message.id), "item_id": ""],
        ])
        _ = try? await dmQuery("useIGDMarkThreadAsReadValidationMutation", variables: [
            "metadata": ["ig_thread_igid": .string(longThreadId)],
            "data": ["message_id": .string(message.id),
                     "message_timestamp_ms": .string(String(Int(message.sentAt.timeIntervalSince1970 * 1000)))],
        ])
    }

    func unsend(_ messageId: String, longThreadId: String) async throws {
        _ = try await dmQuery("IGDMessageUnsendDialogOffMsysMutation", variables: [
            "message_id": .string(messageId), "send_data": ["thread_id": .string(longThreadId)],
        ])
    }

    /// DM queries: the doc ids live in script chunks the home page doesn't load, so they're
    /// looked for on the inbox page, with the last known values as a fallback.
    private func dmQuery(_ name: String, variables: JSON) async throws -> JSON {
        await prepare()
        if knownOperations()[name] == nil { await scanPage("/direct/inbox/") }
        let doc = knownOperations()[name] ?? Self.fallbackDocIds[name]
        do {
            return try await graphQL(name, variables: variables, docId: doc)
        } catch IGError.api(let message) where !healedDocs.contains(name) {
            // A doc id from an older web build: read the inbox page's scripts again, once.
            healedDocs.insert(name)
            forgetDoc(name)
            await scanPage("/direct/inbox/", force: true)
            guard let fresh = knownOperations()[name], fresh != doc else { throw IGError.api(message) }
            return try await graphQL(name, variables: variables, docId: fresh)
        }
    }

    /// Last known DM doc ids (from the web app on 2026-11-12, else from mautrix-instagram).
    nonisolated static let fallbackDocIds: [String: String] = [
        "PolarisDirectInboxQuery": "28881837051457834",
        "IGDirectMediaShareMutation": "29164221929874709",
        "IGDirectReelShareMutation": "28509600205408270",
        "IGDThreadDetailQuery": "29620840297508799",
        "IGDThreadListOffMsysPaginationQuery": "27712934271665380",
        "IGDMessageListOffMsysQuery": "27502152406082940",
        "IGDirectTextSendMutation": "26911679871773184",
        "IGDirectMediaSendMutation": "25766288509716264",
        "IGDirectReactionSendMutation": "24374451552236906",
        "useIGDMarkThreadAsReadMutation": "27356881703909995",
        "useIGDMarkThreadAsReadValidationMutation": "35211594988486314",
        "IGDMessageUnsendDialogOffMsysMutation": "26948700068153789",
    ]
}

/// Offline threading ids: `(unix ms << 22) | (counter << 12) | 42`, unique per message we send.
nonisolated enum OfflineThreadingId {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastMs: Int64 = 0
    nonisolated(unsafe) private static var counter: Int64 = 0

    static func next() -> String {
        lock.lock(); defer { lock.unlock() }
        let ms = Int64(Date.now.timeIntervalSince1970 * 1000)
        counter = ms == lastMs ? (counter + 1) & 0x3FF : 0
        lastMs = ms
        return String((ms << 22) | (counter << 12) | 42)
    }
}
