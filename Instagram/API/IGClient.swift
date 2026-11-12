import Foundation
import OSLog

nonisolated enum IGError: LocalizedError, Sendable, Equatable {
    /// Instagram no longer accepts the session (signed out elsewhere, or the cookies expired).
    case signedOut
    /// Instagram wants the account confirmed on its own site first ("challenge"/"checkpoint").
    case checkpoint(URL?)
    case rateLimited
    case http(Int, String)
    case api(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .signedOut: "Your Instagram session has ended. Sign in again."
        case .checkpoint: "Instagram wants you to confirm your account. Open instagram.com in a browser, then try again."
        case .rateLimited: "Instagram is limiting requests. Try again in a few minutes."
        case .http(let code, _): "Instagram answered with an error (\(code))."
        case .api(let message): message
        case .badResponse: "Instagram sent a response this app couldn't read."
        }
    }
}

/// Talks to instagram.com's own web API with the signed-in session's cookies: the REST
/// endpoints under `/api/v1/` and the Relay GraphQL endpoint (`/api/graphql`) the web app
/// uses. GraphQL queries are addressed by `doc_id`s, read from instagram.com's scripts and
/// refreshed when Instagram ships a new build.
actor IGClient {
    /// Safari's user agent, with this Mac's Safari version: URLSession and WebKit share
    /// Safari's network stack, so requests look like Safari's in every respect.
    nonisolated static let userAgent: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let version = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "26.0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }()

    nonisolated static let origin = "https://www.instagram.com"

    /// The web app posts most queries to `/api/graphql` (some, like the feed, to `/graphql/query`;
    /// both accept either).
    nonisolated static var graphQLPath: String {
        #if DEBUG
        if let p = UserDefaults.standard.string(forKey: "IGGQLPath") { return p }
        #endif
        return "/api/graphql"
    }

    let session: IGSession
    private let http: URLSession
    private(set) var page = WebPageConfig()
    private var registry = DocRegistry.load()
    private var bootstrap: Task<Void, Never>?
    private var pageReloadedAt: Date?
    /// Sent back as `x-ig-www-claim`; Instagram hands out a new one in `x-ig-set-www-claim`.
    private var wwwClaim = "0"
    private var requestCounter = 1
    private let log = Logger(subsystem: "com.subhash.Instagram", category: "API")

    init(session: IGSession, configuration: URLSessionConfiguration = .ephemeral) {
        self.session = session
        let cfg = configuration.copy() as! URLSessionConfiguration
        // Cookies are sent by hand from IGSession; URLSession must not keep its own jar.
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 30
        http = URLSession(configuration: cfg)
    }

    // MARK: Setup

    /// Reads instagram.com's page once for the tokens GraphQL needs (`fb_dtsg`, `lsd`, the
    /// build number) and its script list. Requests wait for it.
    func prepare() async {
        if bootstrap == nil {
            bootstrapAttempts += 1
            lastBootstrap = .now
            bootstrap = Task { await loadAppPage() }
        }
        await bootstrap?.value
        if page.dtsg != nil {
            bootstrapAttempts = 0
        } else if bootstrapAttempts < 2 || Date.now.timeIntervalSince(lastBootstrap) > 60 {
            // The page didn't load (offline at launch) or had no token: try again on the next
            // request, then at most once a minute, so requests don't each fetch the page.
            bootstrap = nil
        }
    }

    private var bootstrapAttempts = 0
    private var lastBootstrap = Date.distantPast

    /// The page's HTML, kept only while the probe asks for it.
    private(set) var lastPageHTML: String?

    private func loadAppPage(keepHTML: Bool = false) async {
        guard let html = try? await fetchText(URL(string: Self.origin + "/")!, accept: "text/html") else {
            log.error("Couldn't load instagram.com's page")
            return
        }
        page = WebPageConfig(html: html)
        if keepHTML { lastPageHTML = html }
        let found = registry.absorb(script: html)
        log.info("App page: \(html.count) chars, \(self.page.scripts.count) scripts, dtsg \(self.page.dtsg == nil ? "missing" : "ok", privacy: .public), \(found) doc ids inline")
        if registry.scannedAt.map({ Date.now.timeIntervalSince($0) > 3 * 86_400 }) ?? true {
            await scanScripts()
        }
        registry.save()
        MemoryRelief.soon()
    }

    /// Reads the page again (a new web build). At most once per 2 minutes.
    @discardableResult
    func reloadAppPage(keepHTML: Bool = false) async -> Bool {
        if !keepHTML, let t = pageReloadedAt, Date.now.timeIntervalSince(t) < 120 { return false }
        pageReloadedAt = .now
        await loadAppPage(keepHTML: keepHTML)
        return true
    }

    /// Reads `doc_id`s from the page's scripts, eight at a time.
    func scanScripts(extra: [URL] = []) async {
        let urls = Array(Set(page.scripts + extra))
        let http = self.http, ua = Self.userAgent
        var found = 0
        for batch in stride(from: 0, to: urls.count, by: 8).map({ Array(urls[$0..<min($0 + 8, urls.count)]) }) {
            let scripts = await withTaskGroup(of: String?.self) { group in
                for url in batch {
                    group.addTask {
                        var r = URLRequest(url: url)
                        r.setValue(ua, forHTTPHeaderField: "User-Agent")
                        guard let (data, _) = try? await http.data(for: r) else { return nil }
                        let s = String(decoding: data, as: UTF8.self)
                        return s.contains("RelayOperation") ? s : nil
                    }
                }
                var out: [String] = []
                for await s in group { if let s { out.append(s) } }
                return out
            }
            for js in scripts { found += registry.absorb(script: js) }
        }
        registry.scannedAt = .now
        registry.save()
        log.info("Scanned \(urls.count) scripts: \(found) doc ids (\(self.registry.docIds.count) known)")
        MemoryRelief.soon()
    }

    func knownOperations() -> [String: String] { registry.docIds }

    /// Reads another page of the site (the inbox, say) for the doc ids its scripts declare.
    /// Once per path per run.
    func scanPage(_ path: String, force: Bool = false) async {
        if force { scannedPages.remove(path) }
        guard scannedPages.insert(path).inserted,
              let html = try? await fetchText(URL(string: Self.origin + path)!, accept: "text/html") else { return }
        _ = registry.absorb(script: html)
        let other = WebPageConfig(html: html)
        if page.dmDeviceId == nil { page.dmDeviceId = other.dmDeviceId }
        if page.messagingId == nil { page.messagingId = other.messagingId }
        await scanScripts(extra: other.scripts)
    }

    private var scannedPages = Set<String>()
    /// DM queries whose doc id was already refreshed this run.
    var healedDocs = Set<String>()

    /// Drops a doc id that Instagram no longer accepts.
    func forgetDoc(_ name: String) {
        registry.docIds[name] = nil
        registry.save()
    }

    // MARK: GraphQL

    /// Runs a Relay query by its friendly name and returns its `data`. A missing or stale
    /// `doc_id` makes it read instagram.com's scripts again, once.
    func graphQL(_ name: String, variables: JSON, docId explicitDoc: String? = nil) async throws -> JSON {
        await prepare()
        var healed = false
        while true {
            if explicitDoc == nil, registry.docIds[name] == nil, !healed {
                healed = true
                await reloadAppPage()
                await scanScripts()
            }
            guard let docId = explicitDoc ?? registry.docIds[name] else { throw IGError.api("Unknown query \(name)") }
            var form = page.commonForm(counter: nextCounter(), userId: await session.userId)
            form["fb_api_caller_class"] = "RelayModern"
            form["fb_api_req_friendly_name"] = name
            form["variables"] = String(decoding: (try? variables.data()) ?? Data("{}".utf8), as: UTF8.self)
            form["server_timestamps"] = "true"
            form["doc_id"] = docId

            var request = URLRequest(url: URL(string: Self.origin + Self.graphQLPath)!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody(form)
            #if DEBUG
            if let dir = UserDefaults.standard.string(forKey: "IGRawDir") {
                let secret: Set = ["fb_dtsg", "lsd", "jazoest", "av", "__hs"]
                let shown = form.sorted { $0.key < $1.key }.map { "\($0.key)=\(secret.contains($0.key) ? "<\($0.value.count) chars>" : $0.value)" }
                try? shown.joined(separator: "\n").write(to: URL(fileURLWithPath: dir).appending(path: "form-\(name).txt"), atomically: true, encoding: .utf8)
            }
            #endif
            request.setValue(name, forHTTPHeaderField: "x-fb-friendly-name")
            if let lsd = page.lsd { request.setValue(lsd, forHTTPHeaderField: "x-fb-lsd") }
            if let nonce = page.entryNonce { request.setValue(nonce, forHTTPHeaderField: "x-fb-entry-nonce") }
            let json = try await send(request, path: Self.graphQLPath)
            dump(name, json)
            if json["data"].isNull, let message = json["errors"][0]["message"].string {
                // A doc id from an old build answers with an error, not a 404.
                if !healed, explicitDoc == nil {
                    healed = true
                    log.info("\(name, privacy: .public): \(message, privacy: .public); rereading scripts")
                    registry.docIds[name] = nil
                    await reloadAppPage()
                    await scanScripts()
                    continue
                }
                throw IGError.api(message)
            }
            return json["data"]
        }
    }

    #if DEBUG
    /// Sends a captured web form as is (debug comparison of our form against the web app's).
    func replay(form: [String: String], path: String) async throws -> JSON {
        await prepare()
        var request = URLRequest(url: URL(string: Self.origin + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(form)
        if let name = form["fb_api_req_friendly_name"] { request.setValue(name, forHTTPHeaderField: "x-fb-friendly-name") }
        if let lsd = form["lsd"] { request.setValue(lsd, forHTTPHeaderField: "x-fb-lsd") }
        return try await send(request, path: path)
    }
    #endif

    // MARK: REST

    enum Method: String, Sendable { case get = "GET", post = "POST" }

    /// `/api/v1/…` on www.instagram.com (`path` starts with `/api/v1/`, or is relative to it).
    func rest(_ method: Method, _ path: String, query: [String: String] = [:], form: [String: String]? = nil) async throws -> JSON {
        await prepare()
        let full = path.hasPrefix("/") ? path : "/api/v1/" + path
        guard var comps = URLComponents(string: Self.origin + full) else { throw IGError.api("Bad path \(path)") }
        if !query.isEmpty {
            // Added to any query already in `path`.
            let added = query.sorted { $0.key < $1.key }.map { "\($0.key)=\(Self.percentEncode($0.value))" }
            comps.percentEncodedQuery = ((comps.percentEncodedQuery.map { [$0] } ?? []) + added).joined(separator: "&")
        }
        var request = URLRequest(url: comps.url!)
        request.httpMethod = method.rawValue
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody(form)
        }
        let json = try await send(request, path: comps.path)
        dump(comps.path.replacingOccurrences(of: "/", with: "_"), json)
        return json
    }

    // MARK: Transport

    private func send(_ base: URLRequest, path: String, retried: Bool = false) async throws -> JSON {
        var request = base
        guard let csrf = await session.csrfToken else { throw IGError.signedOut }
        request.setValue(await session.cookieHeader(for: "www.instagram.com"), forHTTPHeaderField: "Cookie")
        request.setValue(csrf, forHTTPHeaderField: "x-csrftoken")
        request.setValue(page.appId, forHTTPHeaderField: "x-ig-app-id")
        request.setValue(page.asbdId, forHTTPHeaderField: "x-asbd-id")
        // The web app sends these on REST calls only, not on GraphQL.
        if !path.hasSuffix("graphql") && !path.hasSuffix("/graphql/query") {
            request.setValue(wwwClaim, forHTTPHeaderField: "x-ig-www-claim")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "x-requested-with")
        }
        request.setValue("0", forHTTPHeaderField: "X-IG-Max-Touch-Points")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin + "/", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        // What a browser adds to the web app's own requests; Meta's CSRF checks look for them.
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")

        let (data, response) = try await http.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw IGError.badResponse }
        if let fields = response.allHeaderFields as? [String: String], let url = response.url {
            await session.absorb(responseHeaders: fields, url: url)
        }
        if let claim = response.value(forHTTPHeaderField: "x-ig-set-www-claim"), !claim.isEmpty { wwwClaim = claim }

        // GraphQL answers can start with a `for (;;);` guard.
        var body = data
        if body.starts(with: Data("for (;;);".utf8)) { body = body.dropFirst(9) }
        #if DEBUG
        if let dir = UserDefaults.standard.string(forKey: "IGRawDir") {
            try? data.write(to: URL(fileURLWithPath: dir).appending(path: "raw-\(Int(Date.now.timeIntervalSince1970 * 1000)).txt"))
        }
        #endif
        let json = Self.parseBody(body)
        let message = json["message"].string ?? ""

        if message == "checkpoint_required" || message == "challenge_required" {
            throw IGError.checkpoint(json["checkpoint_url"].string.flatMap(URL.init(string:)))
        }
        if message == "login_required" || json["require_login"].bool == true { throw IGError.signedOut }
        // Meta's own error envelope: {"error": 1357054, "errorSummary": …}.
        if let code = json["error"].int, let summary = json["errorSummary"].string {
            if code == 1357001 { throw IGError.signedOut }
            throw IGError.api("\(summary) (\(code))")
        }
        if json["spam"].bool == true || message.localizedCaseInsensitiveContains("wait a few minutes") { throw IGError.rateLimited }

        switch response.statusCode {
        case 200..<300:
            if json == .null {
                // An HTML answer to an API call is the login page: the session is gone.
                if String(decoding: data.prefix(200), as: UTF8.self).contains("<!DOCTYPE") { throw IGError.signedOut }
                throw IGError.badResponse
            }
            if json["status"].string == "fail" { throw IGError.api(message.isEmpty ? "Instagram refused the request." : message) }
            return json
        case 429:
            throw IGError.rateLimited
        case 401:
            throw IGError.signedOut
        case 403 where !retried && message.localizedCaseInsensitiveContains("csrf"):
            // The CSRF token rotated; the response carried the new one.
            return try await send(base, path: path, retried: true)
        default:
            let text = String(decoding: data.prefix(1500), as: UTF8.self)
            log.error("HTTP \(response.statusCode) for \(path, privacy: .public): \(text, privacy: .public)")
            throw IGError.http(response.statusCode, text)
        }
    }

    /// Fetches a page or script from Instagram with the session (for the bootstrap).
    func fetchText(_ url: URL, accept: String) async throws -> String {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if Self.isInstagramHost(url) {
            request.setValue(await session.cookieHeader(for: url.host() ?? "www.instagram.com"), forHTTPHeaderField: "Cookie")
        }
        let (data, response) = try await http.data(for: request)
        if let r = response as? HTTPURLResponse, let fields = r.allHeaderFields as? [String: String], let u = r.url,
           Self.isInstagramHost(u) {
            await session.absorb(responseHeaders: fields, url: u)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Raw bytes with the session's cookies (media that needs them).
    func fetchData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var r = request
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let url = r.url, Self.isInstagramHost(url) {
            r.setValue(await session.cookieHeader(for: url.host() ?? "www.instagram.com"), forHTTPHeaderField: "Cookie")
            if let csrf = await session.csrfToken { r.setValue(csrf, forHTTPHeaderField: "x-csrftoken") }
            r.setValue(page.appId, forHTTPHeaderField: "x-ig-app-id")
        }
        let (data, response) = try await http.data(for: r)
        guard let response = response as? HTTPURLResponse else { throw IGError.badResponse }
        return (data, response)
    }

    /// One JSON document, or several separated by newlines (streamed `@defer`/`@stream`
    /// parts): those are merged, each later part's `data` placed at its `path`.
    nonisolated static func parseBody(_ body: Data) -> JSON {
        if let json = try? JSON(data: body) { return json }
        let parts = body.split(separator: UInt8(ascii: "\n")).compactMap { try? JSON(data: Data($0)) }
        guard var root = parts.first else { return .null }
        for part in parts.dropFirst() where !part["data"].isNull {
            let path = part["path"].array
            root = root.merging(part["data"], at: [JSON.string("data")] + path, label: part["label"].string)
        }
        return root
    }

    private func nextCounter() -> String {
        requestCounter += 1
        return String(requestCounter, radix: 36)
    }

    // MARK: Helpers

    /// instagram.com or a subdomain: the only hosts that get the session's cookies.
    nonisolated static func isInstagramHost(_ url: URL) -> Bool {
        guard let h = url.host()?.lowercased() else { return false }
        return h == "instagram.com" || h.hasSuffix(".instagram.com")
    }

    nonisolated static func formBody(_ form: [String: String]) -> Data {
        Data(form.sorted { $0.key < $1.key }.map { "\($0.key)=\(percentEncode($0.value))" }.joined(separator: "&").utf8)
    }

    nonisolated static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// `-IGDumpDir <folder>` (Debug): saves each response for parser work.
    private func dump(_ name: String, _ json: JSON) {
        #if DEBUG
        guard let dir = UserDefaults.standard.string(forKey: "IGDumpDir"), let data = try? json.data() else { return }
        let url = URL(fileURLWithPath: dir).appending(path: "\(name)-\(Int(Date.now.timeIntervalSince1970 * 1000)).json")
        try? data.write(to: url)
        #endif
    }
}

// MARK: - Page configuration

/// Values read from instagram.com's HTML that the web app sends with its requests.
nonisolated struct WebPageConfig: Sendable {
    var dtsg: String?
    var lsd: String?
    var appId = "936619743392459"
    var asbdId = "359341"
    var rev: String?
    var hsi: String?
    var hs: String?
    var spinR: String?
    var spinB: String?
    var spinT: String?
    /// The account's Meta-wide id, which GraphQL forms send as `av`.
    var actorId: String?
    /// `CurrentUserInitialData.USER_ID` ("0" for Instagram accounts), sent as `__user`.
    var user = "0"
    var jazoest: String?
    /// `BootloaderConfig.nonce`, sent as `X-FB-Entry-Nonce` on GraphQL requests.
    var entryNonce: String?
    /// `IGDMqttWebDeviceID.clientId`: the inbox query and the DM socket send it.
    var dmDeviceId: String?
    /// `CurrentUserInitialData.IG_USER_EIMU`: our own messaging id (DM senders are named by it).
    var messagingId: String?
    var cometReq = "7"
    var dpr = "2"
    /// A random web session id for this run, `xxxxxx:xxxxxx:xxxxxx`.
    var webSessionId: String = (0..<3).map { _ in
        String((0..<6).map { _ in "abcdefghijklmnopqrstuvwxyz0123456789".randomElement()! })
    }.joined(separator: ":")
    var scripts: [URL] = []

    init() {}

    init(html: String) {
        func first(_ pattern: String) -> String? {
            NSRegularExpression(pattern).firstCaptures(in: html)?[1] ?? nil
        }
        dtsg = first(#""DTSGInitialData",\[\],\{"token":"([^"]+)""#) ?? first(#""dtsg":\{"token":"([^"]+)""#)
        lsd = first(#""LSD",\[\],\{"token":"([^"]+)""#) ?? first(#""lsd":\{"token":"([^"]+)""#)
        if let id = first(#""X-IG-App-ID":"(\d+)""#) ?? first(#""appId":"(\d+)""#) ?? first(#""APP_ID":"(\d+)""#) { appId = id }
        if let id = first(#""?(?:asbd_id|ASBD_ID)"?\s*[:=]\s*"?(\d+)"#) { asbdId = id }
        rev = first(#""server_revision":(\d+)"#) ?? first(#""__spin_r":(\d+)"#)
        hsi = first(#""hsi":"(\d+)""#)
        hs = first(#""haste_session":"([^"]+)""#)
        spinR = first(#""__spin_r":(\d+)"#)
        spinB = first(#""__spin_b":"([^"]+)""#)
        spinT = first(#""__spin_t":(\d+)"#)
        actorId = first(#""actorID":"(\d+)""#)
        if let u = first(#""CurrentUserInitialData",\[\],\{[^}]*?"USER_ID":"(\d+)""#) { user = u }
        jazoest = first(#"[?&]jazoest=(\d+)"#)
        dmDeviceId = first(#""IGDMqttWebDeviceID",\[\],\{"clientId":"([^"]+)""#)
        messagingId = first(#""IG_USER_EIMU":"(\d+)""#)
        entryNonce = first(#""BootloaderConfig",\[\],\{[^}]*?"nonce":"([^"]+)""#)
        if let c = first(#"[?&]__comet_req=(\d+)"#) { cometReq = c }
        if let pr = first(#""SiteData",\[\],\{[^}]*?"pr":([\d.]+)"#) { dpr = pr }
        let srcs = NSRegularExpression(#"<script[^>]+src="(https://static\.cdninstagram\.com/rsrc\.php/[^"]+)""#).captures(in: html)
            .compactMap { $0[1] }
        let preloads = NSRegularExpression(#"<link[^>]+href="(https://static\.cdninstagram\.com/rsrc\.php/[^"]+\.js[^"]*)""#).captures(in: html)
            .compactMap { $0[1] }
        scripts = Array(Set((srcs + preloads).map { $0.replacingOccurrences(of: "&amp;", with: "&") })).compactMap(URL.init(string:))
    }

    /// The fields every web GraphQL form carries.
    func commonForm(counter: String, userId: String?) -> [String: String] {
        var f: [String: String] = [
            "av": actorId ?? "0", "__d": "www", "__user": user, "__a": "1", "__req": counter,
            "__comet_req": cometReq, "dpr": dpr, "__ccg": "EXCELLENT", "__s": webSessionId,
        ]
        if let dtsg {
            f["fb_dtsg"] = dtsg
            f["jazoest"] = jazoest ?? "2" + String(dtsg.unicodeScalars.reduce(0) { $0 + Int($1.value) })
        }
        if let lsd { f["lsd"] = lsd }
        if let rev { f["__rev"] = rev }
        if let hsi { f["__hsi"] = hsi }
        if let hs { f["__hs"] = hs }
        if let spinR { f["__spin_r"] = spinR }
        if let spinB { f["__spin_b"] = spinB }
        if let spinT { f["__spin_t"] = spinT }
        return f
    }
}

// MARK: - doc_id registry

/// Relay query names → `doc_id`, read from instagram.com's scripts, which declare each as
/// `__d("PolarisFooQuery_instagramRelayOperation",[],(function(t,n,r,o,a,i){a.exports="123"}),null)` (minified parameter names vary).
nonisolated struct DocRegistry: Codable, Sendable {
    var docIds: [String: String] = [:]
    var scannedAt: Date?

    private static let pattern = NSRegularExpression(#"__d\("([A-Za-z0-9_]+?)_(?:instagram|facebook)?RelayOperation",\[\],\(function\([^)]*\)\{[A-Za-z_$]\.exports="(\d+)""#)

    /// Takes in every declaration in `script`; returns how many it found.
    mutating func absorb(script: String) -> Int {
        let hits = Self.pattern.captures(in: script)
        for h in hits { if let name = h[1], let id = h[2] { docIds[name] = id } }
        return hits.count
    }

    static var url: URL { SessionStore.directory.appending(path: "operations.json") }

    static func load() -> DocRegistry {
        guard let data = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(DocRegistry.self, from: data) else { return DocRegistry() }
        return r
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}
