import Foundation
import OSLog

/// Everything a DGW socket needs from instagram.com's page config and the session.
nonisolated struct DGWParameters: Sendable {
    /// `DGWWebConfig.appId`.
    var appId: String
    /// `PolarisViewer.data.fbid` (== `NON_FACEBOOK_USER_ID`): the web app's `x-dgw-uuid` on every gateway socket.
    var fbid: String
    /// `PolarisViewer.id`, the account's user id (pk): the typing subscription's `user_id`.
    var viewerId: String
    /// `IGDMqttWebDeviceID.clientId`.
    var deviceId: String
    var cookieHeader: String
    var userAgent: String
    /// `prevalidated_graphql_doc_id` of the main stream's sync params.
    var deltaDocId: String
    /// The typing subscription's doc id.
    var typingDocId: String

    /// Where the sockets connect. Replaceable so tests can run a fake gateway.
    nonisolated(unsafe) static var gatewayBase = "wss://gateway.instagram.com/ws/"

    /// `<gatewayBase><path>` with the query the web app sends (same order).
    func url(_ path: String, streamGroup: Bool = false, loggingId: Bool = false) -> URL {
        var items: [(String, String)] = [
            ("x-dgw-appid", appId), ("x-dgw-appversion", "0"), ("x-dgw-authtype", "6:0"), ("x-dgw-version", "5"),
            ("x-dgw-uuid", fbid), ("x-dgw-tier", "prod"),
        ]
        if loggingId { items.append(("x-dgw-loggingid", UUID().uuidString.lowercased())) }
        items.append(("x-dgw-deviceid", deviceId))
        if streamGroup { items.append(("x-dgw-app-stream-group", "group1")) }
        let query = items.map { "\($0.0)=\(IGClient.percentEncode($0.1))" }.joined(separator: "&")
            .replacingOccurrences(of: "%3A", with: ":")
        return URL(string: "\(Self.gatewayBase)\(path)?\(query)")!
    }

    /// The handshake headers a browser sends from www.instagram.com.
    var headers: [String: String] {
        [
            "Cookie": cookieHeader, "User-Agent": userAgent, "Origin": IGClient.origin,
            "Accept-Language": "en-US,en;q=0.9", "Cache-Control": "no-cache", "Pragma": "no-cache",
            "Sec-Fetch-Dest": "empty", "Sec-Fetch-Mode": "websocket", "Sec-Fetch-Site": "same-site",
        ]
    }
}

/// Why a DGW socket ended.
nonisolated struct DGWClose: Error, Sendable, CustomStringConvertible {
    enum Reason: Sendable, Equatable {
        /// The server closed with a WebSocket close code (4003 = unauthorized).
        case closeCode(Int, String)
        /// The upgrade was refused with an HTTP status.
        case http(Int)
        /// No ping or pong from the server for 30 s.
        case keepaliveTimeout
        /// We closed it.
        case closedByClient
        /// A protocol problem (a stream that wouldn't open, a sync failure, …).
        case protocolError(String)
        case network(String)
    }
    var reason: Reason

    var isUnauthorized: Bool {
        switch reason {
        case .closeCode(let c, _): c == DGWCloseCode.unauthorized
        case .http(let s): s == 401 || s == 403
        default: false
        }
    }

    var description: String {
        switch reason {
        case .closeCode(let c, let r): "close \(c)\(r.isEmpty ? "" : " (\(r))")"
        case .http(let s): "HTTP \(s)"
        case .keepaliveTimeout: "keepalive timeout"
        case .closedByClient: "closed"
        case .protocolError(let m): m
        case .network(let m): m
        }
    }
}

/// One DGW WebSocket connection: frames in and out, keepalive pings every 10 s, a 30 s
/// silence timeout, pongs for the server's pings. Streams and reconnecting are the caller's.
actor DGWSocket {
    private let task: URLSessionWebSocketTask
    private let session: URLSession
    private var continuation: AsyncStream<DGWFrame>.Continuation?
    private var lastHeard = Date.now
    private var loops: [Task<Void, Never>] = []
    private(set) var closed: DGWClose?
    let label: String
    private let log = Logger(subsystem: "com.subhash.Instagram", category: "DGW")

    static let pingInterval: Duration = .seconds(10)
    static let silenceTimeout: TimeInterval = 30

    init(url: URL, headers: [String: String], label: String) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        task = session.webSocketTask(with: request)
        // Deltas can be large (a burst replayed after a reconnect).
        task.maximumMessageSize = 16 << 20
        self.label = label
    }

    /// Opens the connection. Incoming frames (other than keepalives, which are handled here)
    /// arrive on the stream, which finishes when the socket closes; `closed` then says why.
    func open() -> AsyncStream<DGWFrame> {
        let (stream, continuation) = AsyncStream.makeStream(of: DGWFrame.self, bufferingPolicy: .unbounded)
        self.continuation = continuation
        task.resume()
        lastHeard = .now
        loops.append(Task { [weak self] in await self?.receiveLoop() })
        loops.append(Task { [weak self] in await self?.keepaliveLoop() })
        return stream
    }

    func send(_ frames: [DGWFrame]) async throws {
        guard closed == nil else { throw closed! }
        try await task.send(.data(DGWFrame.encode(frames)))
    }

    /// Closes the socket (normal closure) and ends the frame stream.
    func close(_ reason: DGWClose.Reason = .closedByClient) {
        finish(reason)
    }

    private func finish(_ reason: DGWClose.Reason) {
        guard closed == nil else { return }
        closed = DGWClose(reason: reason)
        for l in loops { l.cancel() }
        loops = []
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        continuation?.finish()
        continuation = nil
    }

    private func receiveLoop() async {
        while closed == nil {
            do {
                let message = try await task.receive()
                guard case .data(let data) = message else { continue }  // text messages mean nothing in DGW
                lastHeard = .now
                for frame in DGWFrame.decode(data) {
                    switch frame {
                    case .ping:
                        try? await task.send(.data(DGWFrame.encode([.pong])))
                    case .pong:
                        break
                    default:
                        continuation?.yield(frame)
                    }
                }
            } catch {
                finish(closeReason(error))
                return
            }
        }
    }

    private func closeReason(_ error: Error) -> DGWClose.Reason {
        let code = task.closeCode.rawValue
        if code != 0 && code != URLSessionWebSocketTask.CloseCode.invalid.rawValue {
            let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
            return .closeCode(code, String(reason.prefix(200)))
        }
        if let http = task.response as? HTTPURLResponse, http.statusCode != 101 {
            return .http(http.statusCode)
        }
        if error is CancellationError { return .closedByClient }
        return .network((error as NSError).localizedDescription)
    }

    private func keepaliveLoop() async {
        while closed == nil {
            try? await Task.sleep(for: Self.pingInterval)
            guard closed == nil, !Task.isCancelled else { return }
            if Date.now.timeIntervalSince(lastHeard) > Self.silenceTimeout {
                log.info("\(self.label, privacy: .public): no keepalive for \(Int(Self.silenceTimeout))s")
                finish(.keepaliveTimeout)
                return
            }
            try? await task.send(.data(DGWFrame.encode([.ping])))
        }
    }
}
