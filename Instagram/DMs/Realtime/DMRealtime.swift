import Foundation
import OSLog

extension IGClient {
    /// Last known doc ids for the socket's subscriptions (from the web app on 2026-11-12).
    nonisolated static let dgwFallbackDocIds = [
        "IGDSlideDeltaProcessorQuery": "29464536269817547",
        "IGDTypingIndicatorClientSubscription": "28367799366176340",
    ]

    /// The gateway's parameters, from the page config (read first if needed) and the session.
    /// `fresh` reads the page again (a reconnect after the session or build changed).
    func dgwParameters(fresh: Bool = false) async -> DGWParameters? {
        await prepare()
        if fresh { await reloadAppPage() }
        if page.dmDeviceId == nil || page.dgwAppId == nil || page.viewerFbid == nil { await scanPage("/direct/inbox/") }
        let userId = await session.userId
        guard let appId = page.dgwAppId, let fbid = page.viewerFbid, let device = page.dmDeviceId,
              let viewer = page.viewerId ?? userId else { return nil }
        let docs = knownOperations()
        return DGWParameters(
            appId: appId, fbid: fbid, viewerId: viewer, deviceId: device,
            cookieHeader: await session.cookieHeader(for: "gateway.instagram.com"), userAgent: Self.userAgent,
            deltaDocId: docs["IGDSlideDeltaProcessorQuery"] ?? Self.dgwFallbackDocIds["IGDSlideDeltaProcessorQuery"]!,
            typingDocId: docs["IGDTypingIndicatorClientSubscription"] ?? Self.dgwFallbackDocIds["IGDTypingIndicatorClientSubscription"]!)
    }
}

/// Instagram's real-time DM connection (docs/dm-protocol.md §5): the main "lightspeed" stream
/// (mailbox deltas from a sequence id on), the stream controller (others typing) and, only when
/// asked to send typing, the MQTT bypass stream. Reconnects with backoff; `events` reports
/// everything as `DMRealtimeEvent`s.
actor DMRealtime {
    nonisolated let events: AsyncStream<DMRealtimeEvent>
    private let continuation: AsyncStream<DMRealtimeEvent>.Continuation
    private let client: IGClient
    private var seqId: Int64
    private var snapshotAt: Date
    private var mainTask: Task<Void, Never>?
    private var typingTask: Task<Void, Never>?
    private var main: DGWSocket?
    private var bypass: DGWSocket?
    private var bypassReady = false
    private var bypassTask: Task<Void, Never>?
    private(set) var isSubscribed = false
    /// After 4003: nothing reconnects until `start` is called again.
    private var unauthorized = false
    private let log = Logger(subsystem: "com.subhash.Instagram", category: "DGW")

    #if DEBUG
    /// Frame and delta counts for `-IGProbeDGW` (names only, never content).
    private(set) var stats: [String: Int] = [:]
    private(set) var notes: [String] = []
    private func count(_ key: String, _ n: Int = 1) { stats[key, default: 0] += n }
    private func note(_ s: String) { if notes.count < 200 { notes.append(s) } }
    #else
    private func count(_ key: String, _ n: Int = 1) {}
    private func note(_ s: String) {}
    #endif

    /// `seqId` is the inbox query's `iris_inactive_subscription_uq_seq_id`, `snapshotAt` when
    /// that inbox was fetched.
    init(client: IGClient, seqId: Int64, snapshotAt: Date = .now) {
        self.client = client
        self.seqId = seqId
        self.snapshotAt = snapshotAt
        (events, continuation) = AsyncStream.makeStream(of: DMRealtimeEvent.self, bufferingPolicy: .unbounded)
    }

    func start(typing: Bool = true) {
        unauthorized = false
        if mainTask == nil { mainTask = Task { await self.mainLoop() } }
        if typing, typingTask == nil { typingTask = Task { await self.typingLoop() } }
    }

    /// Restarts the main stream from a new snapshot (after `.resnapshot`).
    func restart(seqId: Int64, snapshotAt: Date = .now) {
        self.seqId = seqId
        self.snapshotAt = snapshotAt
        if mainTask == nil {
            mainTask = Task { await self.mainLoop() }
        } else {
            Task { await main?.close() }  // the loop reconnects with the new cursor
        }
    }

    func stop() {
        mainTask?.cancel(); mainTask = nil
        typingTask?.cancel(); typingTask = nil
        bypassTask?.cancel(); bypassTask = nil
        let sockets = [main, bypass]
        main = nil; bypass = nil; bypassReady = false
        Task { for s in sockets { await s?.close() } }
        continuation.finish()
    }

    // MARK: Main stream

    /// A connection only counts as working (and resets the retry backoff) once it has stayed up
    /// this long: one that connects and then drops at once, again and again, must back off too.
    nonisolated static let stableAfter: Duration = .seconds(45)

    /// Seconds to wait before retry number `failures` (1, 2, 4 … 60, plus up to 20% jitter).
    nonisolated static func backoff(failures: Int) -> Double {
        guard failures > 0 else { return 1 }
        let base = min(pow(2, Double(min(failures, 10))), 60)
        return base + Double.random(in: 0...(base * 0.2))
    }

    private func mainLoop() async {
        var failures = 0
        var attempt = 0
        var freshPage = false
        while !Task.isCancelled && !unauthorized {
            let started = ContinuousClock.now
            let result = await runMain(retry: attempt, freshPage: freshPage)
            attempt += 1
            let wasSubscribed = isSubscribed
            isSubscribed = false
            if wasSubscribed { continuation.yield(.disconnected) }
            guard !Task.isCancelled else { return }
            switch result {
            case .unauthorized:
                unauthorized = true
                continuation.yield(.unauthorized)
                return
            case .resnapshot:
                // Wait for `restart(seqId:)` with a fresh inbox snapshot.
                continuation.yield(.resnapshot)
                mainTask = nil
                return
            case .ended(let wasConnected):
                if wasConnected, ContinuousClock.now - started >= Self.stableAfter {
                    failures = 0
                    try? await Task.sleep(for: .seconds(1))
                } else {
                    failures += 1
                    if !wasSubscribed && failures == 1 { continuation.yield(.disconnected) }
                    // A failing connect may be a stale page config (device id, build): reread it.
                    freshPage = !wasConnected && failures % 3 == 0
                    try? await Task.sleep(for: .seconds(Self.backoff(failures: failures)))
                }
            }
        }
    }

    private enum MainResult { case unauthorized, resnapshot, ended(wasConnected: Bool) }

    private func runMain(retry: Int, freshPage: Bool) async -> MainResult {
        guard let p = await client.dgwParameters(fresh: freshPage) else {
            note("main: page config incomplete (no DGW app id, fbid or device id)")
            count("main.noConfig")
            return .ended(wasConnected: false)
        }
        let socket = DGWSocket(url: p.url("lightspeed"), headers: p.headers, label: "main")
        main = socket
        defer { if main === socket { main = nil } }
        let frames = await socket.open()
        count("main.connects")
        do {
            try await socket.send([.establish(stream: 0, parameters: Data("{}".utf8)),
                                   .data(stream: 0, ackId: 0, requiresAck: true, payload: initPayload(p, retry: retry))])
        } catch {
            note("main: send failed: \(error)")
        }
        // The stream must open and subscribe within a few seconds.
        let watchdog = Task { [weak socket] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            await socket?.close(.protocolError("main stream didn't subscribe within 15 s"))
        }
        defer { watchdog.cancel() }
        var established = false
        var connected = false
        for await frame in frames {
            count("main.frame.\(frame.name)")
            switch frame {
            case .establish(let stream, let params):
                let code = DGWFrame.establishCode(params)
                note("main: establish stream \(stream) → \(code.map(String.init) ?? "?")")
                guard code == 200 else {
                    await socket.close(.protocolError("main stream refused (\(code.map(String.init) ?? "no code"))"))
                    break
                }
                established = true
            case .data(let stream, let ackId, let requiresAck, let payload):
                switch handleMain(payload) {
                case .ok(let subscribed):
                    if subscribed && !connected {
                        connected = true
                        isSubscribed = true
                        watchdog.cancel()
                        continuation.yield(.connected)
                    }
                    if requiresAck { try? await socket.send([.ack(stream: stream, ackId: ackId)]) }
                case .resnapshot:
                    await socket.close(.protocolError("resnapshot"))
                    return .resnapshot
                case .failure(let message):
                    // Don't ack: reconnecting makes the server replay from our cursor.
                    await socket.close(.protocolError("sync failure: \(message)"))
                }
            case .endOfData(let stream, let reason):
                note("main: end of data on \(stream), reason \(reason.map(String.init) ?? "-")")
                if reason == 4 {  // AuthError
                    await socket.close(.closeCode(DGWCloseCode.unauthorized, "auth error"))
                } else {
                    await socket.close(.protocolError("main stream closed"))
                }
            case .drain(let reason):
                note("main: drain \(reason)")
            case .deauth:
                note("main: deauth frame")
            case .ack, .ping, .pong, .unsupported:
                break
            }
        }
        let close = await socket.closed ?? DGWClose(reason: .closedByClient)
        note("main: ended (\(close)), established \(established), subscribed \(connected)")
        log.info("Main stream ended: \(close.description, privacy: .public)")
        if close.isUnauthorized { return .unauthorized }
        return .ended(wasConnected: connected)
    }

    private enum Handled { case ok(subscribed: Bool), resnapshot, failure(String) }

    /// A main-stream data frame: `{"request_id":…, "payload":"<base64 LSResponse>"}`.
    private func handleMain(_ payload: Data) -> Handled {
        guard let json = try? JSON(data: payload), let b64 = json["payload"].string,
              let proto = Data(base64Encoded: b64), let ops = LSOperation.decodeResponse(proto) else {
            count("main.undecodable")
            return .ok(subscribed: false)
        }
        var subscribed = false
        for op in ops {
            count("main.op.\(op.name)")
            switch op {
            case .subscribe(let sub, let latest):
                subscribed = true
                note("main: subscribed (replaying \(max(0, latest - sub)) deltas)")
                log.info("Main stream subscribed")
            case .resnapshot(let type, _):
                note("main: resnapshot (type \(type))")
                return .resnapshot
            case .delta(let delta):
                let r = DMDeltaParser.parse(delta)
                for (t, n) in r.typenames { count("delta.\(t)", n) }
                for e in r.events {
                    count("event.\(e.name)")
                    continuation.yield(e)
                }
                if let s = r.maxSeqId, s > seqId { seqId = s; snapshotAt = .now }
            case .failure(let m):
                return .failure(m)
            case .noop, .unknown:
                break
            }
        }
        return .ok(subscribed: subscribed)
    }

    /// The main stream's first data frame (§5.5).
    private func initPayload(_ p: DGWParameters, retry: Int) -> Data {
        func string(_ j: JSON) -> String { String(decoding: (try? j.data()) ?? Data(), as: UTF8.self) }
        let sync: JSON = [
            "user_agent": "WMI Web",
            "snapshot_at_ms": .integer(Int64(snapshotAt.timeIntervalSince1970 * 1000)),
            "prevalidated_graphql_doc_id": .string(p.deltaDocId),
        ]
        let query: JSON = [
            "database": 223, "epoch_id": 0, "failure_count": .integer(Int64(retry)),
            "last_applied_cursor": .string(string(["seq_id": .integer(seqId)])),
            "sync_params": .string(string(sync)), "version": -3,
        ]
        let connect: JSON = [
            "app_id": .string(p.appId), "device_id": .string(p.deviceId), "payload": .string(string(query)),
            "request_id": .integer(Int64(4 + retry)), "type": 2,
        ]
        return (try? connect.data()) ?? Data()
    }

    // MARK: Typing (stream controller)

    private func typingLoop() async {
        var failures = 0
        while !Task.isCancelled && !unauthorized {
            let started = ContinuousClock.now
            let (connected, close) = await runTyping()
            guard !Task.isCancelled else { return }
            if close?.isUnauthorized == true { return }
            let stable = connected && ContinuousClock.now - started >= Self.stableAfter
            failures = stable ? 0 : failures + 1
            try? await Task.sleep(for: .seconds(Self.backoff(failures: failures)))
        }
    }

    private func runTyping() async -> (connected: Bool, close: DGWClose?) {
        guard let p = await client.dgwParameters() else { return (false, nil) }
        let socket = DGWSocket(url: p.url("streamcontroller", streamGroup: true), headers: p.headers, label: "typing")
        let frames = await socket.open()
        count("typing.connects")
        let params: JSON = [
            "x-dgw-app-XRSS-method": "FBGQLS:XDT_DIRECT_REALTIME_EVENT",
            "x-dgw-app-XRSS-doc_id": .string(p.typingDocId),
            "x-dgw-app-XRSS-routing_hint": "IGDTypingIndicatorClientSubscription",
            "x-dgw-app-xrs-body": "true",
            "x-dgw-app-XRS-Accept-Ack": "RSAck",
            "x-dgw-app-XRSS-http_referer": "https://www.instagram.com/direct/inbox/",
        ]
        try? await socket.send([.establish(stream: 0, parameters: (try? params.data()) ?? Data())])
        let watchdog = Task { [weak socket] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            await socket?.close(.protocolError("typing stream didn't start within 15 s"))
        }
        defer { watchdog.cancel() }
        var started = false
        for await frame in frames {
            count("typing.frame.\(frame.name)")
            switch frame {
            case .establish(_, let raw):
                guard DGWFrame.establishCode(raw) == 200 else {
                    await socket.close(.protocolError("typing stream refused"))
                    break
                }
                let body: JSON = [
                    "input_data": ["user_id": .string(p.viewerId)],
                    "%options": ["useOSSResponseFormat": true, "client_has_ods_usecase_counters": true],
                ]
                let payload = Thrift.requestStreamBody((try? body.data()) ?? Data())
                try? await socket.send([.data(stream: 0, ackId: 0, requiresAck: true, payload: payload)])
            case .data(let stream, let ackId, let requiresAck, let payload):
                let (didStart, events) = Self.typingEvents(payload)
                if didStart && !started {
                    started = true
                    watchdog.cancel()
                    note("typing: subscription started")
                    log.info("Typing stream started")
                }
                for e in events {
                    // Our own typing from another device isn't news.
                    if case .typing(_, let user, _) = e, user == p.viewerId { continue }
                    count("event.\(e.name)")
                    continuation.yield(e)
                }
                if requiresAck { try? await socket.send([.ack(stream: stream, ackId: ackId)]) }
            case .endOfData:
                await socket.close(.protocolError("typing stream closed"))
            default:
                break
            }
        }
        let close = await socket.closed
        note("typing: ended (\(close.map(\.description) ?? "-")), started \(started)")
        return (started, close)
    }

    /// A stream-controller data frame: Thrift `Payload`; field 5 is a `StreamResponse` whose
    /// deltas carry a flow status (2 = started) or JSON data.
    static func typingEvents(_ payload: Data) -> (started: Bool, events: [DMRealtimeEvent]) {
        guard let root = Thrift.decodeStruct(payload), let response = root[5] else { return (false, []) }
        var started = false
        var events: [DMRealtimeEvent] = []
        for delta in response[2]?.list ?? [] {
            if delta[1]?.int == 2 { started = true }
            if let bytes = delta[4]?[1]?.binary { events += DMDeltaParser.typing(bytes) }
        }
        return (started, events)
    }

    // MARK: Sending typing (MQTT bypass)

    /// Tells the thread's other members we're typing (or stopped). Opens the MQTT bypass socket
    /// on first use. `threadId` is the thread IGID. Not sent anywhere unless called.
    func setTyping(_ typing: Bool, threadId: String) async throws {
        if !bypassReady { await connectBypass() }
        guard bypassReady, let bypass else { throw DGWClose(reason: .protocolError("typing socket not connected")) }
        let body: JSON = ["action": "indicate_activity", "activity_status": .integer(typing ? 1 : 0),
                          "client_context": "", "thread_id": .string(threadId)]
        let payload = Thrift.mqttPublish((try? body.data()) ?? Data(), topic: "/ig_send_message")
        try await bypass.send([.data(stream: 0, ackId: 0, requiresAck: false, payload: payload)])
    }

    private func connectBypass() async {
        if bypassTask == nil {
            bypassTask = Task { await self.bypassLoop() }
        }
        // Wait up to 5 s for it to open.
        for _ in 0..<50 where !bypassReady {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func bypassLoop() async {
        defer { bypassTask = nil; bypassReady = false; bypass = nil }
        guard let p = await client.dgwParameters() else { return }
        let socket = DGWSocket(url: p.url("mqttbypass", loggingId: true), headers: p.headers, label: "bypass")
        bypass = socket
        let frames = await socket.open()
        try? await socket.send([.establish(stream: 0, parameters: Data("{}".utf8)),
                                .data(stream: 0, ackId: 0, requiresAck: true, payload: Thrift.mqttConnect(deviceId: p.deviceId))])
        for await frame in frames {
            switch frame {
            case .establish(_, let raw) where DGWFrame.establishCode(raw) == 200:
                bypassReady = true
            case .establish:
                await socket.close(.protocolError("typing socket refused"))
            case .data(let stream, let ackId, let requiresAck, _):
                if requiresAck { try? await socket.send([.ack(stream: stream, ackId: ackId)]) }
            case .endOfData:
                await socket.close(.protocolError("typing socket closed"))
            default:
                break
            }
        }
    }
}
