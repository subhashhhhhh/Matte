import Foundation
import OSLog

/// DM writes beyond plain text, as instagram.com's web app does them (read from its scripts,
/// 2026-11-12): uploading photos and videos, editing, forwarding, message requests, starting a
/// chat, replying to stories. None of these are run by probes; the user tests them.
extension IGClient {
    /// Doc ids of the mutations and queries below (the web app's, 2026-11-12). A newer one read
    /// from the scripts wins.
    nonisolated static let dmWriteDocIds: [String: String] = [
        "IGDirectMediaSendMutation": "28887524104237595",
        "IGDirectEditMessageMutation": "28951492551202915",
        "IGDMediaForwardPublisherMutation": "29536362899300769",
        "IGDirectStoryShareReplyMutation": "29327482173525974",
        "PolarisDirectMessageRequestQuery": "30071460809109024",
        "useIGDirectAcceptMessageRequestMutation": "36571001125823973",
    ]

    private func dmCall(_ name: String, variables: JSON) async throws -> JSON {
        await prepare()
        if knownOperations()[name] == nil { await scanPage("/direct/inbox/") }
        let doc = knownOperations()[name] ?? Self.dmWriteDocIds[name] ?? Self.fallbackDocIds[name]
        return try await graphQL(name, variables: variables, docId: doc)
    }

    // MARK: Photos and videos

    /// Uploads a photo or video for a DM and returns its attachment id. The web app uses
    /// Meta's resumable upload service (`rupload.instagram.com/messenger_image|messenger_video/<uuid>`),
    /// falling back to `/ajax/mercury/upload.php`.
    func uploadDMAttachment(file: URL, mimeType: String, isVideo: Bool) async throws -> String {
        do {
            return try await rupload(file: file, mimeType: mimeType, isVideo: isVideo)
        } catch let error as IGError where error == .signedOut {
            throw error
        } catch {
            Logger(subsystem: "com.subhash.Instagram", category: "DMs")
                .info("rupload failed (\(error.localizedDescription, privacy: .public)); trying mercury")
            return try await mercuryUpload(file: file, mimeType: mimeType)
        }
    }

    private func uploadQuery() async -> String {
        let form = page.commonForm(counter: String(Int.random(in: 40...900), radix: 36), userId: await session.userId)
        return form.sorted { $0.key < $1.key }.map { "\($0.key)=\(Self.percentEncode($0.value))" }.joined(separator: "&")
    }

    private func uploadRequest(_ url: URL) async throws -> URLRequest {
        guard let csrf = await session.csrfToken else { throw IGError.signedOut }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.timeoutInterval = 300
        r.setValue(await session.cookieHeader(for: url.host() ?? "www.instagram.com"), forHTTPHeaderField: "Cookie")
        r.setValue(csrf, forHTTPHeaderField: "x-csrftoken")
        r.setValue(page.appId, forHTTPHeaderField: "x-ig-app-id")
        r.setValue(page.asbdId, forHTTPHeaderField: "x-asbd-id")
        if let lsd = page.lsd { r.setValue(lsd, forHTTPHeaderField: "x-fb-lsd") }
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(Self.origin, forHTTPHeaderField: "Origin")
        r.setValue(Self.origin + "/", forHTTPHeaderField: "Referer")
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        r.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        r.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        r.setValue(url.host() == "www.instagram.com" ? "same-origin" : "same-site", forHTTPHeaderField: "Sec-Fetch-Site")
        return r
    }

    private func rupload(file: URL, mimeType: String, isVideo: Bool) async throws -> String {
        await prepare()
        let userId = await session.userId
        guard let viewer = page.viewerId ?? userId else { throw IGError.signedOut }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let consumer = isVideo ? "messenger_video" : (mimeType == "image/gif" ? "messenger_gif" : "messenger_image")
        let url = URL(string: "https://rupload.instagram.com/\(consumer)/\(UUID().uuidString.lowercased())?\(await uploadQuery())")!
        var r = try await uploadRequest(url)
        r.setValue(Self.percentEncode(file.lastPathComponent), forHTTPHeaderField: "X-Entity-Name")
        r.setValue(mimeType, forHTTPHeaderField: "X-Entity-Type")
        r.setValue(String(size), forHTTPHeaderField: "X-Entity-Length")
        r.setValue("0", forHTTPHeaderField: "Offset")
        r.setValue(viewer, forHTTPHeaderField: "ig-u-ds-user-id")
        r.setValue("FILE_ATTACHMENT", forHTTPHeaderField: isVideo ? "video_type" : "image_type")
        r.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await http.upload(for: r, fromFile: file)
        // Instagram may rotate the csrftoken (or other cookies) on this response too.
        if let reply = response as? HTTPURLResponse, let url = reply.url {
            let fields = reply.allHeaderFields as? [String: String] ?? [:]
            await session.absorb(responseHeaders: fields, url: url)
        }
        let json = Self.parseBody(data)
        guard let http = response as? HTTPURLResponse, http.statusCode < 300 else {
            throw IGError.http((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data.prefix(300), as: UTF8.self))
        }
        if let id = json["media_id_str"].string ?? json["media_id"].string ?? json["media_id"].int.map(String.init)
            ?? json["h"].string, !id.isEmpty, id != "0" {
            return id
        }
        throw IGError.api(json["errorSummary"].string ?? json["debug_info"]["message"].string ?? "The upload didn't return an id.")
    }

    private func mercuryUpload(file: URL, mimeType: String) async throws -> String {
        await prepare()
        let url = URL(string: Self.origin + "/ajax/mercury/upload.php?" + (await uploadQuery()))!
        var r = try await uploadRequest(url)
        let boundary = "----WebKitFormBoundary" + String((0..<16).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()! })
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // Built in a temporary file so a video is never held in memory twice.
        let body = FileManager.default.temporaryDirectory.appending(path: "upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: body) }
        FileManager.default.createFile(atPath: body.path, contents: nil)
        let out = try FileHandle(forWritingTo: body)
        out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"farr\"; filename=\"\(file.lastPathComponent)\"\r\nContent-Type: \(mimeType)\r\n\r\n".utf8))
        let input = try FileHandle(forReadingFrom: file)
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { out.write(chunk) }
        try input.close()
        out.write(Data("\r\n--\(boundary)--\r\n".utf8))
        try out.close()
        let (data, response) = try await http.upload(for: r, fromFile: body)
        // Instagram may rotate the csrftoken (or other cookies) on this response too.
        if let reply = response as? HTTPURLResponse, let url = reply.url {
            let fields = reply.allHeaderFields as? [String: String] ?? [:]
            await session.absorb(responseHeaders: fields, url: url)
        }
        let json = Self.parseBody(data.starts(with: Data("for (;;);".utf8)) ? data.dropFirst(9) : data)
        if let code = json["error"].int, code != 0 { throw IGError.api(json["errorSummary"].string ?? "Upload failed (\(code))") }
        guard (response as? HTTPURLResponse)?.statusCode ?? 0 < 300 else { throw IGError.http((response as? HTTPURLResponse)?.statusCode ?? 0, "") }
        // `metadata` is an array for images, an object {"0": {…}} for videos.
        let meta = json["payload"]["metadata"]
        let entry = meta.array.first ?? meta["0"]
        for key in ["fbid", "video_id", "audio_id", "image_id", "gif_id", "file_id"] {
            if let id = entry[key].string ?? entry[key].int.map(String.init), id != "0", !id.isEmpty { return id }
        }
        throw IGError.api("The upload didn't return an id.")
    }

    /// Sends an uploaded photo or video into a thread. Returns the message id.
    @discardableResult
    func sendMedia(attachmentId: String, thread id: String, replyTo: String? = nil, offlineId: String) async throws -> String? {
        let data = try await dmCall("IGDirectMediaSendMutation", variables: [
            "attachment_fbid": .string(attachmentId), "forwarded_from_thread_id": nil, "is_forwarded_from_own_message": nil,
            "offline_threading_id": .string(offlineId), "reply_to_message_id": replyTo.map(JSON.string) ?? .null,
            "thread_id": .string(id),
        ])
        return data.first("message_id")?.string ?? data.first("id")?.string
    }

    // MARK: Edit and forward

    func editMessage(_ messageId: String, thread id: String, text: String) async throws {
        _ = try await dmCall("IGDirectEditMessageMutation", variables: [
            "body": ["sensitive_string_value": .string(text)], "offline_threading_id": .string(OfflineThreadingId.next()),
            "target_item_id": "", "target_message_id": .string(messageId), "thread_id": .string(id),
        ])
    }

    /// Forwards text into another chat (marked "Forwarded", as on Instagram).
    func forwardText(_ text: String, from source: String, ownMessage: Bool, to thread: String) async throws {
        _ = try await dmQueryText(text, thread: thread, recipient: nil, forwardedFrom: source, own: ownMessage,
                                  attribution: "igd_web_chat_tab:in_thread")
    }

    /// Forwards a photo or video (by its attachment id) into another chat.
    func forwardAttachment(_ attachmentId: String, messageId: String, from source: String, ownMessage: Bool, to thread: String) async throws {
        _ = try await dmCall("IGDMediaForwardPublisherMutation", variables: [
            "attachment_fbid": .string(attachmentId), "forwarded_from_thread_id": .string(source),
            "forwarded_from_thread_item_id": .string(messageId), "is_forwarded_from_own_message": .bool(ownMessage),
            "offline_threading_id": .string(OfflineThreadingId.next()), "recipient_users": nil, "thread_id": .string(thread),
        ])
    }

    /// Text send with the options the plain `sendText` leaves out: to a person with no chat yet
    /// (`recipient`, their user id), or forwarded.
    @discardableResult
    func dmQueryText(_ text: String, thread: String?, recipient: String?, forwardedFrom: String? = nil, own: Bool? = nil,
                     attribution: String) async throws -> JSON {
        try await dmCall("IGDirectTextSendMutation", variables: [
            "commands": nil, "forwarded_from_thread_id": forwardedFrom.map(JSON.string) ?? .null,
            "ig_thread_igid": thread.map(JSON.string) ?? .null,
            "is_forwarded_from_own_message": own.map(JSON.bool) ?? .null, "mentioned_user_ids": nil, "mentions": nil,
            "offline_threading_id": .string(OfflineThreadingId.next()),
            "recipient_igids": recipient.map { .array([.string($0)]) } ?? .null,
            "replied_to_client_context": nil, "replied_to_item_id": nil, "reply_to_message_id": nil, "sampled": nil,
            "send_attribution": .string(attribution), "text": ["sensitive_string_value": .string(text)],
        ])
    }

    /// Starts a chat with someone by sending them a first message (their user id). The web app
    /// does the same: a new chat exists once its first message is sent.
    func startChat(with userId: String, text: String) async throws {
        _ = try await dmQueryText(text, thread: nil, recipient: userId, attribution: "igd_web_chat_tab:in_thread")
    }

    // MARK: Message requests

    /// Message requests (`PENDING`) and hidden requests (`SPAM`), newest first.
    func messageRequests() async throws -> (requests: [DMThread], hidden: [DMThread]) {
        await prepare()
        if page.dmDeviceId == nil { await scanPage("/direct/inbox/") }
        let monthAgo = String(Int64(Date.now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970 * 1000))
        let data = try await dmCall("PolarisDirectMessageRequestQuery", variables: [
            "device_id_for_iris_subscription": .string(page.dmDeviceId ?? ""),
            "__relay_internal__pv__IGD30DayAgoTimestampMsrelayprovider": .string(monthAgo),
            "__relay_internal__pv__IGDPinnedThreadsRenderEnabledGKrelayprovider": true,
            "__relay_internal__pv__IGDMaxUnreadMessagesCountrelayprovider": 5,
            "__relay_internal__pv__IGDThreadListActionsEnabledGKrelayprovider": true,
        ])
        func threads(_ box: JSON) -> [DMThread] {
            box["threads_by_folder"]["edges"].array.compactMap { Parser.thread($0["node"]["as_ig_direct_thread"]) }.map {
                var t = $0
                t.isRequest = true
                return t
            }
        }
        let spam = data["spamMailbox"]
        let main = data.object?.first { $0.key != "spamMailbox" }?.value ?? .null
        return (threads(main), threads(spam))
    }

    func acceptRequest(_ threadId: String) async throws {
        _ = try await dmCall("useIGDirectAcceptMessageRequestMutation", variables: [
            "ig_inbox_folder": nil, "offline_threading_id": .string(OfflineThreadingId.next()), "thread_fbid": .string(threadId),
        ])
    }

    // MARK: Stories

    /// Replies to a story (text) or reacts to it (`emoji`), as a DM to its owner (user id).
    func replyToStory(mediaId: String, reelId: String, ownerId: String, text: String?, emoji: String?) async throws {
        let otid = OfflineThreadingId.next()
        _ = try await dmCall("IGDirectStoryShareReplyMutation", variables: [
            "data": ["is_shh_mode": false, "media_id": .string(mediaId), "reaction_emoji": emoji.map(JSON.string) ?? .null,
                     "reel_id": .string(reelId), "sampled": false, "share_client_context": .string(otid),
                     "text": text.map { ["sensitive_string_value": .string($0)] } ?? .null],
            "send_data": ["forwarded_from_thread_id": nil, "is_forwarded_from_own_message": nil, "offline_threading_id": .string(otid),
                          "recipient_users": .string("[\"\(ownerId)\"]"), "thread_id": nil],
        ])
    }
}
