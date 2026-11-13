import Foundation
import CryptoKit

/// Publishing a story with a shared post on it through the phone app's API (`i.instagram.com`).
///
/// instagram.com's `configure_to_story` accepts the post sticker (`reshared_media_id`,
/// `tap_models`) but drops it: the story goes up untappable (seen 2026-11-13; the story items
/// shared from the phone carry `story_feed_media`, Matte's didn't). The phone app's endpoint
/// keeps it. This is the one request Matte sends that way, written from instagrapi
/// (`login_by_sessionid`, `photo_configure_to_story` with `medias`, `media_share_to_story`):
/// the web login's `sessionid` as a `Bearer IGT:2:` header, an Android user agent, the body as
/// `signed_body=SIGNATURE.<json>`. The photo itself is uploaded as before (rupload).
///
/// The phone identity (device ids) is made once per account from its id, so every share looks
/// like the same phone. Failures never sign you out: the caller falls back to the web publish.
extension IGClient {
    nonisolated static let phoneAppId = "567067343352427"
    nonisolated static let phoneAppVersion = "449.0.0.52.84"
    nonisolated static let phoneVersionCode = "1079242191"
    nonisolated static let phoneBloksVersion = "799db3e387d7a21a19c72918b8698b6cd28a1516ade363792c100ed45a0f9f0b"
    nonisolated static let phoneUserAgent = "Instagram \(phoneAppVersion) Android (34/14; 480dpi; 1344x2992; Google/google; "
        + "Pixel 8 Pro; husky; husky; en_US; \(phoneVersionCode))"

    /// A fixed made-up phone for this account: ids derived from the account id.
    nonisolated struct PhoneIdentity: Sendable {
        let uuid: String
        let phoneId: String
        let androidId: String

        init(userId: String) {
            func digest(_ salt: String) -> [UInt8] { Array(SHA256.hash(data: Data("matte-\(salt)-\(userId)".utf8))) }
            func uuidString(_ b: [UInt8]) -> String {
                let hex = b.prefix(16).map { String(format: "%02x", $0) }.joined()
                let c = Array(hex)
                return [String(c[0..<8]), String(c[8..<12]), "4" + String(c[13..<16]), "a" + String(c[17..<20]), String(c[20..<32])]
                    .joined(separator: "-")
            }
            uuid = uuidString(digest("uuid"))
            phoneId = uuidString(digest("phone"))
            androidId = "android-" + digest("android").prefix(8).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Publishes an uploaded photo as a story with `reshare` as a tappable post sticker.
    func configureReshareStoryByPhone(uploadId: String, width: Int, height: Int, reshare: StoryReshare) async throws -> Media? {
        guard let userId = await session.userId, let sessionId = await session.cookie("sessionid") else { throw IGError.signedOut }
        let phone = PhoneIdentity(userId: userId)
        let now = Int(Date.now.timeIntervalSince1970)
        let p = reshare.placement
        let tap: [[String: Any]] = [[
            "x": p.x, "y": p.y, "z": 0, "width": p.width, "height": p.height, "rotation": 0.0,
            "type": "feed_media", "media_id": reshare.mediaPk, "media_owner_id": reshare.ownerId,
            "product_type": "feed", "is_sticker": true, "tap_state": 0, "tap_state_str_id": "feed_post_sticker_square",
        ]]
        let capabilities: [[String: String]] = [
            ["value": (119...142).map { "\($0).0" }.joined(separator: ","), "name": "SUPPORTED_SDK_VERSIONS"],
            ["value": "14", "name": "FACE_TRACKER_VERSION"],
            ["value": "ETC2_COMPRESSION", "name": "COMPRESSION"],
            ["value": "gyroscope_enabled", "name": "gyroscope"],
        ]
        func text(_ o: Any) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data("[]".utf8), as: UTF8.self)
        }
        let body: [String: Any] = [
            "supported_capabilities_new": text(capabilities),
            "has_original_sound": "1",
            "camera_session_id": UUID().uuidString.lowercased(),
            "scene_capture_type": "",
            "timezone_offset": String(TimeZone.current.secondsFromGMT()),
            "client_shared_at": String(now - 5),
            "story_sticker_ids": "",
            "media_folder": "Camera",
            "configure_mode": "1",
            "source_type": "4",
            "creation_surface": "camera",
            "imported_taken_at": now - 3 * 24 * 3600,
            "capture_type": "normal",
            "rich_text_format_types": "[\"modern_refreshed_v2\"]",
            "upload_id": uploadId,
            "client_timestamp": String(now),
            "device": ["manufacturer": "Google/google", "model": "Pixel 8 Pro", "android_version": 34, "android_release": "14"],
            "_uid": userId,
            "_uuid": phone.uuid,
            "device_id": phone.androidId,
            "composition_id": UUID().uuidString.lowercased(),
            "app_attribution_android_namespace": "",
            "media_transformation_info": text(["width": String(width), "height": String(height), "x_transform": "0", "y_transform": "0",
                                               "zoom": "1.0", "rotation": "0.0", "background_coverage": "0.0"]),
            "original_media_type": "photo",
            "camera_entry_point": "25",
            "edits": ["crop_original_size": [Double(width), Double(height)], "filter_type": 0, "filter_strength": 1.0],
            "extra": ["source_width": width, "source_height": height],
            "tap_models": text(tap),
            "reshared_media_id": reshare.mediaPk,
        ]
        let json = text(body)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = json.addingPercentEncoding(withAllowedCharacters: allowed) ?? json

        var r = URLRequest(url: URL(string: "https://i.instagram.com/api/v1/media/configure_to_story/")!)
        r.httpMethod = "POST"
        r.timeoutInterval = 60
        r.httpShouldHandleCookies = false
        r.httpBody = Data("signed_body=SIGNATURE.\(encoded)".utf8)
        let auth = ["ds_user_id": userId, "sessionid": sessionId, "should_use_header_over_cookies": true] as [String: Any]
        let headers: [String: String] = [
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
            "User-Agent": Self.phoneUserAgent,
            "Authorization": "Bearer IGT:2:" + Data(text(auth).utf8).base64EncodedString(),
            "X-IG-App-ID": Self.phoneAppId,
            "X-IG-App-Locale": "en_US", "X-IG-Device-Locale": "en_US", "X-IG-Mapped-Locale": "en_US",
            "X-IG-Device-ID": phone.uuid,
            "X-IG-Family-Device-ID": phone.phoneId,
            "X-IG-Android-ID": phone.androidId,
            "X-IG-Timezone-Offset": String(TimeZone.current.secondsFromGMT()),
            "X-IG-Connection-Type": "WIFI",
            "X-IG-Capabilities": "3brTv10=",
            "X-Bloks-Version-Id": Self.phoneBloksVersion,
            "X-Bloks-Is-Layout-RTL": "false",
            "X-IG-WWW-Claim": "0",
            "X-MID": await session.cookie("mid") ?? "",
            "IG-U-DS-USER-ID": userId,
            "IG-INTENDED-USER-ID": userId,
            "X-FB-HTTP-Engine": "Liger",
            "Accept-Language": "en-US",
        ]
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        #if DEBUG
        try Self.dryRun("phone/configure_to_story", request: r)
        #endif
        // Its own session: nothing from this answer touches the web login's cookies.
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let answer = (try? JSON(data: data)) ?? .null
        guard status == 200, answer["status"].string == "ok" else {
            let message = answer["message"].string ?? answer["error_title"].string ?? "HTTP \(status)"
            throw IGError.api("Phone publish refused: \(message)")
        }
        return Parser.media(answer["media"])
    }
}
