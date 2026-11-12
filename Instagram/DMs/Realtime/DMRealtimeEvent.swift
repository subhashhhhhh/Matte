import Foundation

/// What the real-time DM connection reports (docs/dm-protocol.md §5–6). Thread ids are the
/// thread IGID (`DMThread.id`) unless named otherwise.
nonisolated enum DMRealtimeEvent: Equatable, Sendable {
    /// The main stream is subscribed: deltas now arrive as they happen.
    case connected
    /// The connection dropped; it reconnects by itself (poll meanwhile).
    case disconnected
    /// The gateway refused the session (close 4003). Real-time stops.
    case unauthorized
    /// The saved sequence id is too old: fetch the inbox again and restart from its seq id.
    case resnapshot

    /// A new message (also our own, echoed back with its `offlineId`).
    case message(thread: String, DMMessage)
    case messageEdited(thread: String, messageId: String, text: String?)
    case messageDeleted(thread: String, messageId: String)
    /// A reaction added (`emoji` set) or removed (`emoji` nil; the sender may be unknown).
    case reaction(thread: String, messageId: String, emoji: String?, senderId: String?)
    /// Another participant read up to `at` (`participantId` is a messaging id).
    case readReceipt(thread: String, participantId: String, at: Date)
    /// We read the thread on another device.
    case markedRead(thread: String)
    /// Someone is typing (or stopped). Typing names the thread by its *long* id and the user
    /// by their user id (pk).
    case typing(longThreadId: String, userId: String, isTyping: Bool)
    /// Something else changed in the thread (renamed, muted, members, unread…): refetch it.
    case threadChanged(thread: String)
    /// Activity status of people, keyed by messaging id. `full` = this is the server's whole
    /// list (entries not in it are no longer known), else only changes.
    case presence([String: Presence], full: Bool)

    /// A short name for logs and the probe (no content).
    var name: String {
        switch self {
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .unauthorized: "unauthorized"
        case .resnapshot: "resnapshot"
        case .message: "message"
        case .messageEdited: "messageEdited"
        case .messageDeleted: "messageDeleted"
        case .reaction: "reaction"
        case .readReceipt: "readReceipt"
        case .markedRead: "markedRead"
        case .typing: "typing"
        case .threadChanged: "threadChanged"
        case .presence: "presence"
        }
    }

    var threadId: String? {
        switch self {
        case .message(let t, _), .messageEdited(let t, _, _), .messageDeleted(let t, _), .reaction(let t, _, _, _),
             .readReceipt(let t, _, _), .markedRead(let t), .threadChanged(let t): t
        default: nil
        }
    }
}

/// Turns the main stream's delta JSON into events.
nonisolated enum DMDeltaParser {
    struct Result {
        var events: [DMRealtimeEvent] = []
        /// The highest `uq_seq_id` seen (the cursor to resume from).
        var maxSeqId: Int64?
        /// `__typename` → count, for logs and the probe.
        var typenames: [String: Int] = [:]
    }

    /// `delta` is the `OnMailboxDelta.delta` string: `[{"data":{"slide_delta_processor":[…]}}]`.
    static func parse(_ delta: String) -> Result {
        var result = Result()
        guard let json = try? JSON(data: Data(delta.utf8)) else { return result }
        let wrappers = json.array.isEmpty ? [json] : json.array
        for w in wrappers {
            for d in w["data"]["slide_delta_processor"].array {
                let type = d["__typename"].string ?? "?"
                result.typenames[type, default: 0] += 1
                if let seq = d["uq_seq_id"].int.map(Int64.init) { result.maxSeqId = max(result.maxSeqId ?? seq, seq) }
                if let e = event(d, type: type) { result.events.append(e) }
            }
        }
        return result
    }

    static func event(_ d: JSON, type: String) -> DMRealtimeEvent? {
        let message = d["message"]
        let thread = nonEmpty(d["thread_fbid"].string) ?? nonEmpty(message["thread_fbid"].string)
            ?? nonEmpty(d["thread"]["id"].string) ?? ""
        let messageId = d["message_id"].string ?? ""
        switch type {
        case "SlideUQPPNewMessage", "SlideUQPPNewRavenMessage", "SlideUQPPNewGenieMessage", "SlideUQPPAdminTextMessage":
            guard !thread.isEmpty else { return nil }
            guard let m = Parser.message(message) else { return .threadChanged(thread: thread) }
            return .message(thread: thread, m)
        case "SlideUQPPCreateReaction", "SlideUQPPDeleteReaction":
            guard !thread.isEmpty, !messageId.isEmpty else { return thread.isEmpty ? nil : .threadChanged(thread: thread) }
            let r = d["reaction"]
            let sender = r["sender_fbid"].string.flatMap { $0 == "0" ? nil : $0 }
            return .reaction(thread: thread, messageId: messageId,
                             emoji: type == "SlideUQPPCreateReaction" ? r["reaction"].string : nil, senderId: sender)
        case "SlideUQPPReadReceipt":
            let r = d["read_receipt"]
            guard !thread.isEmpty, let who = r["participant_fbid"].string, let at = Parser.ms(r["watermark_timestamp_ms"]) else {
                return thread.isEmpty ? nil : .threadChanged(thread: thread)
            }
            return .readReceipt(thread: thread, participantId: who, at: at)
        case "SlideUQPPMarkRead":
            return thread.isEmpty ? nil : .markedRead(thread: thread)
        case "SlideUQPPEditMessage":
            guard !thread.isEmpty, !messageId.isEmpty else { return thread.isEmpty ? nil : .threadChanged(thread: thread) }
            return .messageEdited(thread: thread, messageId: messageId, text: d["text_body"].string)
        case "SlideUQPPDeleteMessage":
            guard !thread.isEmpty, !messageId.isEmpty else { return thread.isEmpty ? nil : .threadChanged(thread: thread) }
            return .messageDeleted(thread: thread, messageId: messageId)
        case "SlideUQPPNoOpMutation", "SlideUQPPNotYetImplementedMutation", "SlideUQPPCreate1To1Thread",
             "SlideUQPPUserReachabilityStatus":
            return nil
        default:
            return thread.isEmpty ? nil : .threadChanged(thread: thread)
        }
    }

    /// A stream-controller typing patch (§5.8): `{"data":{"xdt_direct_realtime_event":{"event":"patch","data":[…]}}}`.
    static func typing(_ data: Data) -> [DMRealtimeEvent] {
        guard let json = try? JSON(data: data) else { return [] }
        let evt = json["data"]["xdt_direct_realtime_event"]
        guard evt["event"].string == "patch" else { return [] }
        return evt["data"].array.compactMap { p -> DMRealtimeEvent? in
            guard p["op"].string == "add", let path = p["path"].string,
                  let thread = typingThread(path),
                  let raw = p["value"].string, let value = try? JSON(data: Data(raw.utf8)) else { return nil }
            let sender = value["sender_id"].string ?? value["sender_id"].int.map(String.init) ?? ""
            return .typing(longThreadId: thread, userId: sender, isTyping: (value["activity_status"].int ?? 0) == 1)
        }
    }

    /// A presence publish (`PresenceUnifiedJSON` stream):
    /// `{"publishType":1 (full) | 2 (incremental),"presenceUpdates":[{"userId":"<messaging id>",
    /// "presenceStatus":2 (active) | 0,"lastActiveTimeSeconds":…}]}`. `userId` "0" entries are skipped.
    static func presence(_ data: Data) -> DMRealtimeEvent? {
        guard let json = try? JSON(data: data), case .array(let updates) = json["presenceUpdates"] else { return nil }
        var out: [String: Presence] = [:]
        for u in updates {
            let id = u["userId"].string ?? u["userId"].int.map(String.init) ?? ""
            guard !id.isEmpty, id != "0" else { continue }
            let seconds = u["lastActiveTimeSeconds"].double ?? 0
            out[id] = Presence(isActive: u["presenceStatus"].int == 2,
                               lastActive: seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil)
        }
        let full = json["publishType"].int == 1
        if out.isEmpty && !full { return nil }
        return .presence(out, full: full)
    }

    /// The long thread id in `/direct_v2/threads/<id>/activity_indicator_id/<x>`.
    static func typingThread(_ path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 5, parts[0] == "direct_v2", parts[1] == "threads", parts[3] == "activity_indicator_id",
              !parts[2].isEmpty, parts[2].allSatisfy(\.isNumber) else { return nil }
        return String(parts[2])
    }

    private static func nonEmpty(_ s: String?) -> String? { s.flatMap { $0.isEmpty || $0 == "0" ? nil : $0 } }
}
