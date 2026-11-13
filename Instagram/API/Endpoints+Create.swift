import Foundation
import Synchronization

/// Posting, editing and deleting your own posts, reels and stories, request for request as
/// instagram.com sent them (recorded 2026-11-12; the sequence and every field are in
/// docs/create-protocol.md). Uploads go to Meta's resumable upload service on
/// `i.instagram.com` as raw bytes; the post itself is then "configured" from the upload id.
extension IGClient {
    /// Options the create dialog offers for a post or reel.
    nonisolated struct PostOptions: Sendable, Equatable {
        var caption = ""
        var hideCounts = false
        var commentsOff = false
        /// Instagram publishes it then (professional accounts) instead of now.
        var scheduledAt: Date?
    }

    /// The clips-creation flow id the web app tags its reel publish with (recorded).
    nonisolated static let clipsFlowId = "379199405"
    nonisolated static let ruploadHost = "https://i.instagram.com"
    /// The web app sends a video in 10 MB pieces, asking for the offset before each.
    nonisolated static let videoChunkSize = 10_000_000

    nonisolated static let createDocIds: [String: String] = [
        "usePolarisStoriesV3DeleteMediaMutation": "27648950741394648",
        "PolarisPostFastOptionToggleCommentingLegacyEnableMutation": "28230802399856833",
    ]

    // MARK: Upload ids

    private nonisolated static let lastUploadId = Mutex<Int64>(0)

    /// `PolarisUploadHelpers.createUploadId`: the time in milliseconds, kept increasing.
    nonisolated static func newUploadId() -> String {
        lastUploadId.withLock { last in
            let now = Int64(Date.now.timeIntervalSince1970 * 1000)
            last = last >= now ? last + 1 : now
            return String(last)
        }
    }

    // MARK: rupload

    nonisolated enum RuploadService: String, Sendable {
        case photo = "rupload_igphoto"
        case video = "rupload_igvideo"
    }

    /// The headers every rupload request carries (recorded): no CSRF token, no www-claim; the
    /// app id, the touch points and the web session id. Cookies go along (`withCredentials`).
    private func ruploadRequest(_ service: RuploadService, entity: String, method: String, mobile: Bool) async throws -> URLRequest {
        await prepare()
        guard await session.csrfToken != nil else { throw IGError.signedOut }
        let url = URL(string: "\(Self.ruploadHost)/\(service.rawValue)/\(entity)")!
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 300
        r.setValue(await session.cookieHeader(for: "i.instagram.com"), forHTTPHeaderField: "Cookie")
        r.setValue("*/*", forHTTPHeaderField: "Accept")
        r.setValue(page.asbdId, forHTTPHeaderField: "X-ASBD-ID")
        r.setValue(mobile ? Self.mobileAppId : page.appId, forHTTPHeaderField: "X-IG-App-ID")
        r.setValue(mobile ? "5" : "0", forHTTPHeaderField: "X-IG-Max-Touch-Points")
        r.setValue(page.webSessionId, forHTTPHeaderField: "X-Web-Session-ID")
        r.setValue(mobile ? Self.mobileUserAgent : Self.userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue(Self.origin, forHTTPHeaderField: "Origin")
        r.setValue(Self.origin + "/", forHTTPHeaderField: "Referer")
        r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        r.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        r.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        r.setValue("same-site", forHTTPHeaderField: "Sec-Fetch-Site")
        return r
    }

    /// Sends one rupload request and reads its JSON answer.
    private func ruploadSend(_ r: URLRequest, progress: (@Sendable (Int64) -> Void)?) async throws -> JSON {
        let delegate = UploadProgress(progress)
        let (data, response) = try await http.data(for: r, delegate: delegate)
        guard let reply = response as? HTTPURLResponse else { throw IGError.badResponse }
        if let url = reply.url {
            await session.absorb(responseHeaders: reply.allHeaderFields as? [String: String] ?? [:], url: url)
        }
        let json = Self.parseBody(data)
        guard (200..<300).contains(reply.statusCode) else {
            if reply.statusCode == 401 || json["message"].string == "login_required" { throw IGError.signedOut }
            if reply.statusCode == 429 { throw IGError.http(429, "rate limited") }
            throw IGError.http(reply.statusCode, String(decoding: data.prefix(400), as: UTF8.self))
        }
        if json["status"].string == "fail" {
            throw IGError.api(json["message"].string ?? json["debug_info"]["message"].string ?? "Instagram refused the upload.")
        }
        return json
    }

    /// `GET rupload_igvideo/<entity>`: how much of the video Instagram already has.
    func ruploadVideoOffset(entity: String, mobile: Bool = false) async throws -> Int {
        let r = try await ruploadRequest(.video, entity: entity, method: "GET", mobile: mobile)
        #if DEBUG
        if Self.dryRunRecord("rupload_igvideo-offset", request: r, bodySize: 0) { return 0 }
        #endif
        let json = try await ruploadSend(r, progress: nil)
        return json["offset"].int ?? 0
    }

    /// One rupload POST: `bytes` of a file of `total` bytes, starting at `offset`.
    func ruploadPost(_ service: RuploadService, entity: String, params: OrderedJSON, bytes: Data, offset: Int, total: Int,
                     entityType: String?, contentType: String, mobile: Bool,
                     progress: (@Sendable (Int64) -> Void)? = nil) async throws -> JSON {
        var r = try await ruploadRequest(service, entity: entity, method: "POST", mobile: mobile)
        r.setValue(String(offset), forHTTPHeaderField: "Offset")
        r.setValue(String(total), forHTTPHeaderField: "X-Entity-Length")
        r.setValue(entity, forHTTPHeaderField: "X-Entity-Name")
        if let entityType { r.setValue(entityType, forHTTPHeaderField: "X-Entity-Type") }
        if let rev = page.rev { r.setValue(rev, forHTTPHeaderField: "X-Instagram-AJAX") }
        r.setValue(params.text, forHTTPHeaderField: "X-Instagram-Rupload-Params")
        r.setValue(contentType, forHTTPHeaderField: "Content-Type")
        r.httpBody = bytes
        #if DEBUG
        if Self.dryRunRecord(service.rawValue, request: r) {
            progress?(Int64(bytes.count))
            let id = params["upload_id"]?.stringValue ?? ""
            return service == .photo ? ["upload_id": .string(id), "status": "ok"] : ["media_id": .integer(0), "status": "ok"]
        }
        #endif
        return try await ruploadSend(r, progress: progress)
    }

    /// `X-Instagram-Rupload-Params` for a photo (`PolarisAPIRuploadPhoto`): media type 1, or 2
    /// for a video's cover.
    nonisolated static func photoParams(uploadId: String, width: Int, height: Int, mediaType: Int) -> OrderedJSON {
        .object([("media_type", .int(mediaType)), ("upload_id", .string(uploadId)),
                 ("upload_media_height", .int(height)), ("upload_media_width", .int(width)),
                 ("provenance_metadata", .string(#"{"origin":["EXTERNAL"]}"#))])
    }

    /// `X-Instagram-Rupload-Params` for a video (`PolarisAPIRuploadVideo`). A reel (recorded) is
    /// a "clips" video sent without a file type; a story video (from the scripts) is a "reel"
    /// publish mode upload (`for_album`) that keeps the file's type.
    nonisolated static func videoParams(uploadId: String, durationMs: Int, width: Int, height: Int, story: Bool) -> OrderedJSON {
        var fields: [(String, OrderedJSON)] = [("client-passthrough", .string("1"))]
        fields.append(story ? ("is_unified_video", .string("0")) : ("is_clips_video", .string("1")))
        fields += [("for_album", .bool(story)), ("is_sidecar", .string("0")), ("media_type", .int(2)),
                   ("upload_id", .string(uploadId)), ("upload_media_duration_ms", .int(durationMs)),
                   ("upload_media_height", .int(height)), ("upload_media_width", .int(width)),
                   ("video_format", .string(story ? "video/mp4" : "")), ("video_transform", .null),
                   ("provenance_metadata", .string(#"{"origin":["EXTERNAL"]}"#))]
        return .object(fields)
    }

    /// Uploads a JPEG (`PolarisAPIRuploadPhoto.uploadPhoto`), retrying a 429 or 500 after 2,
    /// 4, … 64 seconds as `polarisWithExponentialBackoff` does.
    func uploadPhoto(_ file: URL, uploadId: String, entity: String, width: Int, height: Int, mediaType: Int = 1,
                     mobile: Bool = false, progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let bytes = try Data(contentsOf: file)
        let params = Self.photoParams(uploadId: uploadId, width: width, height: height, mediaType: mediaType)
        var wait: UInt64 = 2
        while true {
            do {
                _ = try await ruploadPost(.photo, entity: entity, params: params, bytes: bytes, offset: 0, total: bytes.count,
                                          entityType: "image/jpeg", contentType: "image/jpeg", mobile: mobile, progress: progress)
                return
            } catch IGError.http(let code, _) where (code == 429 || code == 500) && wait <= 64 {
                try await Task.sleep(for: .seconds(wait))
                wait *= 2
            }
        }
    }

    /// Uploads a reel's video as the web app does (`polarisResumableVideoUpload`): ask for the
    /// offset, send the next 10 MB from there, repeat until it's all in. A dropped connection
    /// is retried up to 10 times, 30 seconds apart.
    func uploadReelVideo(_ file: URL, uploadId: String, durationMs: Int, width: Int, height: Int,
                         progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let entity = "fb_uploader_" + uploadId
        let total = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard total > 0 else { throw IGError.api("The video file is empty.") }
        let params = Self.videoParams(uploadId: uploadId, durationMs: durationMs, width: width, height: height, story: false)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var failures = 0
        while true {
            do {
                let offset = try await ruploadVideoOffset(entity: entity)
                try handle.seek(toOffset: UInt64(offset))
                let bytes = try handle.read(upToCount: Self.videoChunkSize) ?? Data()
                let base = Int64(offset)
                var chunkProgress: (@Sendable (Int64) -> Void)?
                if let progress { chunkProgress = { @Sendable sent in progress(base + sent) } }
                _ = try await ruploadPost(.video, entity: entity, params: params, bytes: bytes, offset: offset, total: total,
                                          entityType: nil, contentType: "application/octet-stream", mobile: false,
                                          progress: chunkProgress)
                failures = 0
                if offset + bytes.count >= total { return }
                #if DEBUG
                // A dry run's offset is always 0: one piece is enough to show the request.
                if UserDefaults.standard.string(forKey: "IGDryRunWrites") != nil { return }
                #endif
            } catch let error as URLError where error.code != .cancelled {
                failures += 1
                if failures >= 10 { throw error }
                try await Task.sleep(for: .seconds(30))
            }
        }
    }

    /// A story's video (`PolarisStoryCreationActions.uploadStoryVideo`, never recorded: the web
    /// app only lets a phone pick photos): one POST of the whole file, no offset check.
    func uploadStoryVideo(_ file: URL, uploadId: String, entity: String, durationMs: Int, width: Int, height: Int,
                          progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        let params = Self.videoParams(uploadId: uploadId, durationMs: durationMs, width: width, height: height, story: true)
        _ = try await ruploadPost(.video, entity: entity, params: params, bytes: bytes, offset: 0, total: bytes.count,
                                  entityType: nil, contentType: "video/mp4", mobile: true, progress: progress)
    }

    // MARK: Publishing

    /// A JSON or form POST to `/api/v1/…` with the given header set, dry-run aware.
    private func createPost(_ path: String, form: [String: String]? = nil, json: OrderedJSON? = nil,
                            headers set: HeaderSet = .standard, extraHeaders: [String: String] = [:], name: String) async throws -> JSON {
        await prepare()
        var r = URLRequest(url: URL(string: Self.origin + path)!)
        r.httpMethod = "POST"
        r.timeoutInterval = 60
        if let json {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data(json.text.utf8)
        } else {
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.httpBody = Self.formBody(form ?? [:])
        }
        for (k, v) in extraHeaders { r.setValue(v, forHTTPHeaderField: k) }
        return try await send(r, path: path, headers: set, dryRun: name)
    }

    /// The fields `PolarisCreationAPI.prepareConfigureMediaData` sends for a plain post or reel
    /// (no location, tags, collaborators or alt text), in its order.
    /// Scheduled (`o.scheduledAt`): the schedule fields too, in the same alphabetical order.
    nonisolated static func configureFields(uploadId: String, options o: PostOptions) -> [(String, OrderedJSON)] {
        let base: [(String, OrderedJSON)] = [("archive_only", .bool(false)), ("caption", .string(o.caption)), ("clips_share_preview_to_feed", .string("1")),
         ("disable_comments", .string(o.commentsOff ? "1" : "0")), ("disable_oa_reuse", .bool(false)),
         ("like_and_view_counts_disabled", .string(o.hideCounts ? "1" : "0")), ("media_share_flow", .string("creation_flow")),
         ("source_type", .string("library")), ("upload_id", .string(uploadId)), ("video_subtitles_enabled", .string("0"))]
        guard let at = o.scheduledAt else { return base }
        return (base + scheduleFields(at)).sorted { $0.0 < $1.0 }
    }

    /// Form values as the browser writes them (`false` → "false").
    private nonisolated static func formValues(_ fields: [(String, OrderedJSON)]) -> [String: String] {
        var f: [String: String] = [:]
        for (k, v) in fields { f[k] = v.formValue }
        return f
    }

    /// Publishes one uploaded photo (recorded: `media/configure/`, a form with the page tokens).
    func configurePhoto(uploadId: String, options: PostOptions) async throws -> Media? {
        var form = formTokens()
        form.merge(Self.formValues(Self.configureFields(uploadId: uploadId, options: options))) { $1 }
        let json = try await createPost("/api/v1/media/configure/", form: form, name: "media/configure")
        return Parser.media(json["media"])
    }

    /// Publishes uploaded photos as one carousel (recorded: `media/configure_sidecar/`, a JSON
    /// body with the page tokens at the end).
    func configureSidecar(uploadIds: [String], options o: PostOptions) async throws -> Media? {
        // Only a single photo's scheduled publish has been recorded so far.
        if o.scheduledAt != nil { throw IGError.api("Scheduling a carousel isn't supported yet. Schedule a single photo, or post it now.") }
        let tokens = formTokens()
        let body = OrderedJSON.object([
            ("archive_only", .bool(false)), ("caption", .string(o.caption)),
            ("children_metadata", .array(uploadIds.map { .object([("upload_id", .string($0))]) })),
            ("client_sidecar_id", .string(String(Int64(Date.now.timeIntervalSince1970 * 1000)))),
            ("disable_comments", .string(o.commentsOff ? "1" : "0")), ("like_and_view_counts_disabled", .int(o.hideCounts ? 1 : 0)),
            ("media_share_flow", .string("creation_flow")), ("source_type", .string("library")),
            ("jazoest", .string(tokens["jazoest"] ?? "")), ("fb_dtsg", .string(tokens["fb_dtsg"] ?? "")),
        ])
        let json = try await createPost("/api/v1/media/configure_sidecar/", json: body, name: "media/configure_sidecar")
        return Parser.media(json["media"])
    }

    /// One `configure_to_clips` attempt (recorded): a comet form with the page fields, the
    /// configure fields, and the same fields signed (`SIGNATURE.` + their JSON).
    private func configureClipsOnce(uploadId: String, options: PostOptions) async throws -> JSON {
        if options.scheduledAt != nil { throw IGError.api("Scheduling a reel isn't supported yet. Schedule a single photo, or post it now.") }
        await prepare()
        let fields = Self.configureFields(uploadId: uploadId, options: options)
        var form = page.commonForm(counter: nextCounter(), userId: await session.userId)
        form["av"] = nil
        form["__crn"] = "comet.igweb.PolarisFeedRoute"
        form["qpl_active_flow_ids"] = Self.clipsFlowId
        form.merge(Self.formValues(fields)) { $1 }
        form["signed_body"] = "SIGNATURE." + OrderedJSON.object(fields).text
        let json = try await createPost("/api/v1/media/configure_to_clips/", form: form, headers: .comet(api: true),
                                        extraHeaders: ["X-FB-QPL-Active-Flows": Self.clipsFlowId], name: "media/configure_to_clips")
        return json["payload"].isNull ? json : json["payload"]
    }

    /// Publishes an uploaded reel. While Instagram is still processing the video it answers
    /// 202; the web app (`polarisConfigureToClipsRetry`) asks again after 3, 6, 12 … 64 s (20
    /// times at most), and after 1, 2, 4, 8 s on a server error (10 times).
    func configureClips(uploadId: String, options: PostOptions, onWaiting: (@Sendable () -> Void)? = nil) async throws -> Media? {
        var pending = 0, serverErrors = 0
        while true {
            let payload: JSON
            do {
                payload = try await configureClipsOnce(uploadId: uploadId, options: options)
            } catch IGError.http(let code, let text) where (500..<600).contains(code) {
                guard serverErrors < 10 else { throw IGError.http(code, text) }
                try await Task.sleep(for: .milliseconds(min(1000 << serverErrors, 8000)))
                serverErrors += 1
                continue
            }
            if let media = Parser.media(payload["media"]) { return media }
            if payload["statusCode"].int == 202 {
                guard pending < 20 else { throw IGError.api("Instagram is still processing the video. Try again in a minute.") }
                onWaiting?()
                try await Task.sleep(for: .milliseconds(min(3000 << pending, 64000)))
                pending += 1
                continue
            }
            if payload["status"].string == "ok" || payload["status"].string == "pending" { return nil }
            throw IGError.api(payload["message"].string ?? payload["error_title"].string ?? "Instagram didn't publish the reel.")
        }
    }

    /// Publishes an uploaded story. A photo (recorded in phone mode): caption and Facebook
    /// fields empty, `configure_mode` 1. A video (from the scripts): only `configure_mode` and
    /// the upload id.
    ///
    /// A video is transcoded by Instagram after the upload; until it's done the publish fails
    /// with "Transcode not finished yet." (seen 2026-11-13, a 57 s story). Ask again, as the
    /// reel publish does for its 202: after 3, 6, 12, then every 15 s, for about 4 minutes.
    func configureStory(uploadId: String, isVideo: Bool, reshare: StoryReshare? = nil,
                        onWaiting: (@Sendable () -> Void)? = nil) async throws -> Media? {
        var attempt = 0
        while true {
            do {
                return try await configureStoryOnce(uploadId: uploadId, isVideo: isVideo, reshare: reshare)
            } catch where isVideo && Self.isTranscodePending(error) && attempt < 20 {
                onWaiting?()
                try await Task.sleep(for: .milliseconds(min(3000 << attempt, 15000)))
                attempt += 1
            }
        }
    }

    /// Instagram's "the video isn't ready yet" answer, however it arrives (error status or body).
    nonisolated static func isTranscodePending(_ error: Error) -> Bool {
        let text: String = switch error as? IGError {
        case .http(_, let body): body
        case .api(let message): message
        default: error.localizedDescription
        }
        return text.localizedCaseInsensitiveContains("transcode not finished")
    }

    private func configureStoryOnce(uploadId: String, isVideo: Bool, reshare: StoryReshare?) async throws -> Media? {
        var form = formTokens()
        if let reshare { form.merge(Self.reshareFields(reshare)) { $1 } }
        form["configure_mode"] = "1"
        form["upload_id"] = uploadId
        if !isVideo {
            form["caption"] = ""
            form["share_to_facebook"] = ""
            form["share_to_fb_destination_id"] = ""
            form["share_to_fb_destination_type"] = "USER"
        }
        let json = try await createPost("/api/v1/media/configure_to_story/", form: form, headers: .mobile, name: "media/configure_to_story")
        return Parser.media(json["media"])
    }

    /// A post or reel on the story as a tappable sticker (instagrapi's `photo_configure_to_story`
    /// with `medias`; the web app has no such request). Numbers as fractions of the story.
    nonisolated static func reshareFields(_ r: StoryReshare) -> [String: String] {
        func n(_ v: Double) -> String { String(format: "%.7f", min(max(v, 0), 4)) }
        let p = r.placement
        let tap = "[{" + [
            "\"x\":\(n(p.x))", "\"y\":\(n(p.y))", "\"z\":0",
            "\"width\":\(n(p.width))", "\"height\":\(n(p.height))", "\"rotation\":0.0",
            "\"type\":\"feed_media\"", "\"media_id\":\(OrderedJSON.quote(r.mediaPk))",
            "\"media_owner_id\":\(OrderedJSON.quote(r.ownerId))", "\"product_type\":\"feed\"",
            "\"is_sticker\":true", "\"tap_state\":0", "\"tap_state_str_id\":\"feed_post_sticker_square\"",
        ].joined(separator: ",") + "}]"
        return ["reshared_media_id": r.mediaPk, "tap_models": tap]
    }

    // MARK: Your posts

    /// Changes a post's caption (recorded: `media/<pk>/edit_media/`, JSON). Collaborators are
    /// sent unchanged; tags only on a post without any, as the recordings show (the web app
    /// sends them only when they changed).
    func editCaption(_ text: String, media m: Media) async throws {
        let tokens = formTokens()
        let unchanged = OrderedJSON.object([("added", .array([])), ("in", .array([])), ("removed", .array([]))]).text
        var fields: [(String, OrderedJSON)] = [("caption_text", .string(text)), ("coauthor_invites", .string(unchanged))]
        if m.hasUsertags != true { fields.append(("usertags", .string(unchanged))) }
        fields += [("jazoest", .string(tokens["jazoest"] ?? "")), ("fb_dtsg", .string(tokens["fb_dtsg"] ?? ""))]
        _ = try await createPost("/api/v1/media/\(m.pk)/edit_media/", json: .object(fields), name: "media/edit_media")
    }

    /// Deletes a post or reel (recorded: `web/create/<pk>/delete/`, a comet form with only the
    /// page fields, from your profile's posts tab).
    func deletePost(pk: String) async throws {
        await prepare()
        var form = page.commonForm(counter: nextCounter(), userId: await session.userId)
        form["av"] = nil
        form["__crn"] = "comet.igweb.PolarisProfilePostsTabRoute"
        let json = try await createPost("/api/v1/web/create/\(pk)/delete/", form: form, headers: .comet(api: false), name: "web/create/delete")
        let payload = json["payload"].isNull ? json : json["payload"]
        guard payload["did_delete"].bool == true else { throw IGError.api("Instagram didn't delete the post.") }
    }

    /// Deletes one of your stories (recorded: `usePolarisStoriesV3DeleteMediaMutation`, the
    /// bare media pk as `mediaId`).
    func deleteStory(pk: String) async throws {
        await prepare()
        let name = "usePolarisStoriesV3DeleteMediaMutation"
        let doc = knownOperations()[name] ?? Self.createDocIds[name]
        let data = try await graphQL(name, variables: ["mediaId": .string(pk)], docId: doc)
        guard data["xdt_api__v1__create__delete"]["did_delete"].bool == true else { throw IGError.api("Instagram didn't delete the story.") }
    }

    /// Turns commenting on (recorded: the "Legacy" enable mutation) or off (its counterpart,
    /// never recorded: only works once its doc id is found in instagram.com's scripts).
    func setCommentsEnabled(_ enabled: Bool, pk: String) async throws {
        await prepare()
        let name = enabled ? "PolarisPostFastOptionToggleCommentingLegacyEnableMutation"
                           : "PolarisPostFastOptionToggleCommentingLegacyDisableMutation"
        guard let doc = knownOperations()[name] ?? Self.createDocIds[name] else {
            throw IGError.api("Matte hasn't seen how instagram.com turns commenting off yet. Turn it off on instagram.com for now.")
        }
        _ = try await graphQL(name, variables: ["input": mutationInput(["media_id": .string(pk)])], docId: doc)
    }
}

// MARK: - Upload progress

/// Reports how many bytes of a request body have gone out.
private nonisolated final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    let report: (@Sendable (Int64) -> Void)?
    init(_ report: (@Sendable (Int64) -> Void)?) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report?(totalBytesSent)
    }
}

// MARK: - Ordered JSON

/// JSON written with its keys in a set order and escaped as JavaScript's `JSON.stringify`
/// escapes (no `\/`, non-ASCII as is): signed bodies and rupload params must read exactly as
/// the web app writes them.
nonisolated indirect enum OrderedJSON: Sendable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case null
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    subscript(key: String) -> OrderedJSON? {
        if case .object(let pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    var stringValue: String? { if case .string(let s) = self { s } else { nil } }

    /// How a browser form writes the value.
    var formValue: String {
        switch self {
        case .string(let s): s
        case .bool(let b): b ? "true" : "false"
        case .int(let n): String(n)
        case .null: "null"
        case .array, .object: text
        }
    }

    var text: String {
        switch self {
        case .string(let s): Self.quote(s)
        case .bool(let b): b ? "true" : "false"
        case .int(let n): String(n)
        case .null: "null"
        case .array(let a): "[" + a.map(\.text).joined(separator: ",") + "]"
        case .object(let pairs): "{" + pairs.map { Self.quote($0.0) + ":" + $0.1.text }.joined(separator: ",") + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
