#if DEBUG
import Foundation

/// Debug-only, read-only probes against the saved session, for building parsers from real
/// responses. Never use them for actions (likes, follows, messages…). Each writes to
/// `-IGProbeOut <file>` and quits.
///
/// - `-IGProbeRest <path> [-IGProbeQuery 'a=1&b=2']`: GET a `/api/v1/` endpoint.
/// - `-IGProbeGQL <FriendlyName> [-IGProbeVars '{json}'] [-IGProbeDoc <doc_id>]`: run a Relay query.
/// - `-IGProbePage YES`: writes the page HTML, its config and the known doc ids next to the
///   output file, and saves the page's scripts in a `scripts/` folder there.
/// - `-IGProbeDGW YES [-IGProbeSeconds 30] [-IGProbeDGWRewind N]`: connects the real-time DM
///   sockets and only listens; writes frame/delta/event counts (no content).
enum DebugProbe {
    static func runIfAsked() async {
        let d = UserDefaults.standard
        guard let out = d.string(forKey: "IGProbeOut") else { return }
        let args = ProcessInfo.processInfo.arguments
        func raw(_ key: String) -> String? {
            args.firstIndex(of: "-" + key).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        guard let session = IGSession.restore() else { fail("not signed in") }
        let client = IGClient(session: session)
        let outURL = URL(fileURLWithPath: out)
        do {
            let json: JSON
            if let path = raw("IGProbeRest") {
                var query: [String: String] = [:]
                for pair in (raw("IGProbeQuery") ?? "").split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    if kv.count == 2 { query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
                }
                // `-IGProbePost YES`: send it as a form POST (read-only endpoints that use POST).
                if UserDefaults.standard.bool(forKey: "IGProbePost") {
                    json = try await client.rest(.post, path, form: query)
                } else {
                    json = try await client.rest(.get, path, query: query)
                }
            } else if d.bool(forKey: "IGProbeArchive") {
                // Read-only: archive days and the first days' stories (counts only), and the edit form.
                let days = try await client.archiveDays()
                let reels = try await client.archiveReels(Array(days.days.prefix(3).map(\.id)))
                let form = try await client.editableProfile()
                json = ["days": .integer(Int64(days.days.count)), "more": .bool(days.next != nil),
                        "stories": .array(reels.values.map { .integer(Int64($0.count)) }),
                        "formHasUsername": .bool(!form.username.isEmpty)]
            } else if let name = raw("IGProbeGQL") {
                let vars = try JSON(data: Data((raw("IGProbeVars") ?? "{}").utf8))
                json = ["data": try await client.graphQL(name, variables: vars, docId: raw("IGProbeDoc"))]
            } else if d.bool(forKey: "IGProbeEndpoints") {
                // Read-only check of every parser against live data; prints counts, not content.
                var out: [String: JSON] = [:]
                let feed = try await client.homeFeed()
                out["feed"] = .string("\(feed.items.count) posts, kinds \(Set(feed.items.map(\.kind.rawValue)).sorted()), images \(feed.items.filter { !$0.images.isEmpty }.count), users \(feed.items.filter { $0.user != nil }.count), more \(feed.hasMore)")
                if let c = feed.cursor { let p2 = try await client.homeFeed(after: c); out["feed2"] = .string("\(p2.items.count) posts, overlap \(Set(p2.items.map(\.pk)).intersection(feed.items.map(\.pk)).count)") }
                let reels = try await client.reels()
                out["reels"] = .string("\(reels.items.count) reels, with video \(reels.items.filter { !$0.videos.isEmpty }.count), more \(reels.hasMore)")
                if let c = reels.cursor { let p2 = try await client.reels(after: c); out["reels2"] = .string("\(p2.items.count) reels") }
                let tray = try await client.storyTray()
                out["tray"] = .string("\(tray.count) reels, unseen \(tray.filter { !$0.seen }.count)")
                if !tray.isEmpty {
                    let r = try await client.storyReels(ids: tray.prefix(3).map(\.id))
                    out["stories"] = .string("\(r.count) reels, items \(r.map(\.items.count)), videos \(r.flatMap(\.items).filter(\.isVideo).count)")
                }
                let inbox = try await client.inbox()
                out["inbox"] = .string("\(inbox.threads.count) threads, unread \(inbox.threads.filter(\.isUnread).count), groups \(inbox.threads.filter(\.isGroup).count), long ids \(inbox.threads.filter { $0.longId != nil }.count), seq \(inbox.seqId != nil), more \(inbox.hasMore)")
                if let c = inbox.cursor, inbox.hasMore { let older = try await client.olderThreads(cursor: c); out["inbox2"] = .string("\(older.threads.count) threads") }
                if let t = inbox.threads.first {
                    let th = try await client.thread(t.id)
                    var kinds: [String: Int] = [:]
                    for m in th.messages.items { kinds[String(describing: m.body).prefix { $0 != "(" }.description, default: 0] += 1 }
                    out["thread"] = .string("\(th.messages.items.count) messages \(kinds), more \(th.messages.hasMore)")
                    if let c = th.messages.cursor, th.messages.hasMore {
                        let older = try await client.olderMessages(thread: t.id, cursor: c)
                        out["thread2"] = .string("\(older.items.count) older, overlap \(Set(older.items.map(\.id)).intersection(th.messages.items.map(\.id)).count)")
                    }
                }
                json = .object(out)
            } else if let file = raw("IGProbeReplay") {
                // `-IGProbeReplay <capture.json> [-IGProbeDrop 'k1,k2']`: replays a captured form.
                let cap = try JSON(data: Data(contentsOf: URL(fileURLWithPath: file)))
                var form = (cap["form"].object ?? [:]).compactMapValues(\.string)
                for k in (raw("IGProbeDrop") ?? "").split(separator: ",") { form[String(k)] = nil }
                let path = URL(string: cap["url"].string ?? "")?.path() ?? "/api/graphql"
                json = try await client.replay(form: form, path: path)
            } else if d.bool(forKey: "IGProbeDGW") {
                // `-IGProbeDGW YES [-IGProbeSeconds 30]`: connects the real-time DM sockets and
                // only listens. Records frame, operation, delta and event counts (no content).
                let seconds = d.double(forKey: "IGProbeSeconds") > 0 ? d.double(forKey: "IGProbeSeconds") : 30
                let inbox = try await client.inbox()
                guard let seq = inbox.seqId.flatMap(Int64.init) else { fail("inbox has no seq id") }
                let params = await client.dgwParameters()
                // `-IGProbeDGWRewind N`: start N deltas back, so the server replays recent ones
                // (exercises the delta parser on real data; still read-only).
                let rewind = Int64(d.integer(forKey: "IGProbeDGWRewind"))
                let rt = DMRealtime(client: client, seqId: max(0, seq - rewind),
                                    snapshotAt: rewind > 0 ? .now.addingTimeInterval(-86_400) : .now)
                // `-IGProbePresenceReport YES`: also report our own availability (IDLE) as the web app does.
                await rt.configurePresence(enabled: true, reportOwn: d.bool(forKey: "IGProbePresenceReport"))
                let participants = Set(inbox.threads.flatMap { t in t.users.compactMap(\.messagingId).filter { $0 != t.viewerMessagingId } })
                if !d.bool(forKey: "IGProbePresenceNoContacts") { await rt.watchPresence(Array(participants)) }
                await rt.start(typing: true)
                let started = Date.now
                var events: [String: Int] = [:]
                var firstConnectedAfter: Double?
                let known = Set(inbox.threads.map(\.id))
                let collector = Task {
                    var local: [String: Int] = [:]
                    var connectedAt: Double?
                    var seen: [String: Presence] = [:]
                    local["presence.asked"] = participants.count
                    local["inbox.threads"] = inbox.threads.count
                    local["inbox.usersWithoutMessagingId"] = inbox.threads.flatMap(\.users).filter { $0.messagingId == nil }.count
                    for await e in rt.events {
                        local[e.name, default: 0] += 1
                        if case .presence(let u, let full) = e {
                            local[full ? "presence.full" : "presence.incremental", default: 0] += 1
                            seen.merge(u) { $1 }
                            // Counts only: how many people, active, with a time, in our threads.
                            local["presence.people"] = seen.count
                            local["presence.active"] = seen.values.filter(\.isActive).count
                            local["presence.withLastActive"] = seen.values.filter { $0.lastActive != nil }.count
                            local["presence.threadParticipants"] = seen.keys.filter(participants.contains).count
                            local["presence.lastActiveWithinDay"] = seen.values.filter { ($0.lastActive ?? .distantPast) > .now.addingTimeInterval(-86_400) }.count
                        }
                        // Do event thread ids name inbox threads (the first page's)?
                        if let t = e.threadId { local[known.contains(t) ? "threadId.inInbox" : "threadId.notOnFirstPage", default: 0] += 1 }
                        if e == .connected, connectedAt == nil { connectedAt = Date.now.timeIntervalSince(started) }
                    }
                    return (local, connectedAt)
                }
                try? await Task.sleep(for: .seconds(seconds))
                let stats = await rt.stats, notes = await rt.notes
                await rt.stop()
                (events, firstConnectedAfter) = await collector.value
                json = [
                    "config": [
                        "dgwAppId": .bool(params?.appId.isEmpty == false), "fbid": .bool(params?.fbid.isEmpty == false),
                        "deviceId": .bool(params?.deviceId.isEmpty == false), "viewerId": .bool(params?.viewerId.isEmpty == false),
                        "deltaDocId": params.map { .string($0.deltaDocId) } ?? .null,
                        "typingDocId": params.map { .string($0.typingDocId) } ?? .null,
                    ],
                    "seconds": .number(seconds),
                    "connectedAfter": firstConnectedAfter.map(JSON.number) ?? .null,
                    "events": .object(events.mapValues { .integer(Int64($0)) }),
                    "stats": .object(stats.mapValues { .integer(Int64($0)) }),
                    "notes": .array(notes.map(JSON.string)),
                ]
            } else if let path = raw("IGProbePagePath") {
                // Any page's HTML and scripts (a post page loads the like/save/share code).
                let dir = outURL.deletingLastPathComponent()
                let html = try await client.fetchText(URL(string: IGClient.origin + path)!, accept: "text/html")
                try Data(html.utf8).write(to: dir.appending(path: "page.html"))
                let scripts = WebPageConfig(html: html).scripts
                let scriptsDir = dir.appending(path: "scripts")
                try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
                for (i, url) in scripts.enumerated() {
                    if let js = try? await client.fetchText(url, accept: "*/*") {
                        try? Data(js.utf8).write(to: scriptsDir.appending(path: "\(i).js"))
                    }
                }
                json = ["scripts": .integer(Int64(scripts.count))]
            } else if d.bool(forKey: "IGProbeWrites") {
                // `-IGProbeWrites YES -IGDryRunWrites <folder>`: runs every write Matte makes with
                // made-up ids. The dry run writes each request to the folder and sends nothing.
                guard d.string(forKey: "IGDryRunWrites") != nil else { fail("-IGProbeWrites needs -IGDryRunWrites <folder>") }
                var post = Media(id: "1000000000000000001_2000000001", pk: "1000000000000000001", kind: .image)
                post.productType = "feed"; post.trackingToken = "TRACKING"; post.loggingToken = "LOGGING"
                var reel = post; reel.productType = "clips"
                var story = Media(id: "1000000000000000002_2000000002", pk: "1000000000000000002", kind: .image)
                story.user = User(id: "2000000002", username: "someone", fullName: "")
                story.expiresAt = .now.addingTimeInterval(3600); story.takenAt = .now
                let thread = "1000000000000001", longThread = "340282366841710300000000000000000001"
                var msg = DMMessage(id: "mid.$TEST", senderId: "1", sentAt: .now, body: .text("x"))
                msg.offlineId = nil
                let calls: [(String, () async throws -> Void)] = [
                    ("like", { try await client.setLiked(true, media: post) }),
                    ("unlike", { try await client.setLiked(false, media: post) }),
                    ("save", { try await client.setSaved(true, media: post) }),
                    ("unsave", { try await client.setSaved(false, media: post) }),
                    ("collection add", { try await client.addToCollection("17900000000000001", media: post) }),
                    ("collection remove", { try await client.removeFromCollection("17900000000000001", media: post) }),
                    ("collection create", { _ = try await client.createCollection(named: "c", with: post) }),
                    ("recent search remove", { try await client.removeRecentKeyword("test") }),
                    ("repost", { _ = try await client.repost(media: post) }),
                    ("unrepost", { try await client.deleteRepost(noteId: "900000000000001") }),
                    ("repost text", { try await client.updateRepost(noteId: "900000000000001", text: "t") }),
                    ("comment", { _ = try await client.postComment("c", media: post.pk) }),
                    ("comment reply", { _ = try await client.postComment("r", media: post.pk, replyTo: "18000000000000001") }),
                    ("comment like", { try await client.setCommentLiked(true, comment: "18000000000000001") }),
                    ("comment unlike", { try await client.setCommentLiked(false, comment: "18000000000000001") }),
                    ("comment delete", { try await client.deleteComment("18000000000000001", media: post.pk) }),
                    ("story seen", { try await client.markStorySeen(reelId: "2000000002", media: story) }),
                    ("story like", { try await client.setStoryLiked(true, media: story) }),
                    ("story unlike", { try await client.setStoryLiked(false, media: story) }),
                    ("story reply", { try await client.replyToStory(mediaId: story.pk, reelId: "2000000002", ownerId: "2000000002", text: nil, emoji: "😍") }),
                    ("story share", { try await client.shareStory(story, reelId: "2000000002", to: .user("2000000003")) }),
                    ("share post", { try await client.share(post, to: .user("2000000003")) }),
                    ("share reel", { try await client.share(reel, to: .user("2000000003")) }),
                    ("forward reel", { try await client.share(reel, to: .thread(thread), forwardedFrom: longThread, own: true) }),
                    ("text", { _ = try await client.sendText("hi", thread: thread, offlineId: OfflineThreadingId.next()) }),
                    ("reply", { _ = try await client.sendText("hi", thread: thread, replyTo: "mid.$TEST", offlineId: OfflineThreadingId.next()) }),
                    ("new chat", { try await client.startChat(with: "2000000003", text: "hi") }),
                    ("forward text", { try await client.forwardText("hi", from: longThread, ownMessage: true, to: thread) }),
                    ("react", { try await client.react("😍", to: "mid.$TEST", thread: thread) }),
                    ("unreact", { try await client.react(nil, previous: "😍", to: "mid.$TEST", thread: thread) }),
                    ("edit", { try await client.editMessage("mid.$TEST", thread: thread, text: "e") }),
                    ("pin", { try await client.setPinned(true, message: "mid.$TEST", thread: thread) }),
                    ("unpin", { try await client.setPinned(false, message: "mid.$TEST", thread: thread) }),
                    ("mark read", { try await client.markRead(longThreadId: longThread, message: msg) }),
                    ("unsend", { try await client.unsend("mid.$TEST", longThreadId: longThread) }),
                    ("media send", { _ = try await client.sendMedia(attachmentId: "1000000000000003", thread: thread, offlineId: OfflineThreadingId.next()) }),
                    ("follow", { _ = try await client.setFollowing(true, userId: "2000000003") }),
                    ("unfollow", { _ = try await client.setFollowing(false, userId: "2000000003") }),
                    ("activity seen", { try await client.markActivitySeen() }),
                ]
                var results: [String: JSON] = [:]
                for (label, call) in calls {
                    do { try await call(); results[label] = "sent?!" } catch { results[label] = .string(error.localizedDescription) }
                }
                let tmp = FileManager.default.temporaryDirectory.appending(path: "probe-\(UUID().uuidString).jpg")
                try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: tmp)
                do { _ = try await client.uploadDMAttachment(file: tmp, mimeType: "image/jpeg", isVideo: false) } catch {
                    results["upload"] = .string(error.localizedDescription)
                }
                try? FileManager.default.removeItem(at: tmp)
                json = .object(results)
            } else if d.bool(forKey: "IGProbeCreate") {
                // `-IGProbeCreate YES -IGDryRunWrites <folder>`: every create flow, dry run only.
                guard d.string(forKey: "IGDryRunWrites") != nil else { fail("-IGProbeCreate needs -IGDryRunWrites <folder>") }
                json = try await DebugCreate.probe(client)
            } else if d.bool(forKey: "IGProbePage") {
                await client.reloadAppPage(keepHTML: true)
                let dir = outURL.deletingLastPathComponent()
                let html = await client.lastPageHTML ?? ""
                try Data(html.utf8).write(to: dir.appending(path: "page.html"))
                let page = await client.page
                let scriptsDir = dir.appending(path: "scripts")
                try FileManager.default.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
                for (i, url) in page.scripts.enumerated() {
                    if let js = try? await client.fetchText(url, accept: "*/*") {
                        try? Data(js.utf8).write(to: scriptsDir.appending(path: "\(i).js"))
                    }
                }
                await client.scanScripts()
                json = [
                    "dtsg": page.dtsg.map(JSON.string) ?? .null, "lsd": page.lsd.map(JSON.string) ?? .null,
                    "appId": .string(page.appId), "asbdId": .string(page.asbdId), "rev": page.rev.map(JSON.string) ?? .null,
                    "scripts": .array(page.scripts.map { .string($0.absoluteString) }),
                    "docIds": .object(await client.knownOperations().mapValues(JSON.string)),
                ]
            } else {
                fail("nothing to probe")
            }
            try json.data().write(to: outURL)
            exit(0)
        } catch {
            fail("\(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("probe: \(message)\n".utf8))
        exit(1)
    }
}
#endif
