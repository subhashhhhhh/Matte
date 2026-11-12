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

    /// The phone-sized web app's id and browser (recorded posting a story in phone mode).
    nonisolated static let mobileAppId = "1217981644879628"
    nonisolated static let mobileUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1"

    /// The web app posts most queries to `/api/graphql` (some, like the feed, to `/graphql/query`;
    /// both accept either).
    nonisolated static var graphQLPath: String {
        #if DEBUG
        if let p = UserDefaults.standard.string(forKey: "IGGQLPath") { return p }
        #endif
        return "/api/graphql"
    }

    let session: IGSession
    let http: URLSession
    private(set) var page = WebPageConfig()
    private var registry = DocRegistry.load()
    private var bootstrap: Task<Void, Never>?
    private var pageReloadedAt: Date?
    /// Sent back as `x-ig-www-claim`; Instagram hands out a new one in `x-ig-set-www-claim`.
    private var wwwClaim = "0"
    private var requestCounter = 1
    /// The web app numbers its Relay mutations' `client_mutation_id` "1", "2", … per page load.
    private var mutationCounter = 0
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
        if page.dgwAppId == nil { page.dgwAppId = other.dgwAppId }
        if page.viewerFbid == nil { page.viewerFbid = other.viewerFbid }
        if page.viewerId == nil { page.viewerId = other.viewerId }
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
            form.merge(Self.mutationContext(name)) { $1 }

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
            #if DEBUG
            if name.hasSuffix("Mutation") { try Self.dryRun(name, form: form, path: Self.graphQLPath) }
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

    /// The page context instagram.com adds to its mutations (recorded 2026-11-12): the route
    /// they're sent from (`__crn`), and on DM sends the messaging flow id
    /// (`qpl_active_flow_ids`, also in `fb_api_analytics_tags`). Queries get nothing extra.
    nonisolated static func mutationContext(_ name: String) -> [String: String] {
        guard name.hasSuffix("Mutation") else { return [:] }
        let route: String
        if name.contains("Story") || name.contains("Stories") {
            route = "PolarisStoriesV3Route"
        } else if name.hasPrefix("IGD") || name.hasPrefix("useIGD") {
            route = name == "IGDirectMediaShareMutation" ? "PolarisFeedRoute" : "PolarisDirectInboxRoute"
        } else if name.contains("Follow") || name.hasPrefix("PolarisPostFastOption") || name.hasPrefix("PolarisPostOption") {
            // Your own post's ⋯ options are used from your profile (recorded: commenting toggle).
            route = "PolarisProfilePostsTabRoute"
        } else {
            route = "PolarisFeedRoute"
        }
        var f = ["__crn": "comet.igweb." + route]
        let flows: [String: String] = [
            "IGDirectTextSendMutation": "25313175,354954279", "IGDirectReelShareMutation": "25313175,354954279",
            "useIGDMarkThreadAsReadMutation": "354954279", "useIGDMarkThreadAsReadValidationMutation": "354954279",
            "IGDirectEditMessageMutation": "354954279", "IGDirectMediaSendMutation": "354954279",
            "IGDirectMediaShareMutation": "354954279", "IGDirectReactionSendMutation": "354954279",
            "IGDirectStoryShareMutation": "354954279", "IGDirectStoryShareReplyMutation": "354954279",
        ]
        if let ids = flows[name] {
            f["qpl_active_flow_ids"] = ids
            f["fb_api_analytics_tags"] = "[\"qpl_active_flow_ids=\(ids)\"]"
        }
        return f
    }

    #if DEBUG
    /// `-IGDryRunWrites <folder>` (Debug): every write (GraphQL mutation, REST POST, DM upload)
    /// is written to the folder as JSON (name, path, form with tokens redacted, variables)
    /// instead of being sent, and fails with "Dry run". For comparing Matte's requests with
    /// recordings of instagram.com without touching the account.
    nonisolated static func dryRun(_ name: String, form: [String: String], path: String) throws {
        guard let dir = UserDefaults.standard.string(forKey: "IGDryRunWrites") else { return }
        let secret: Set = ["fb_dtsg", "lsd", "jazoest", "av", "__hs", "__hsi", "__rev", "__spin_r", "__spin_t", "__s"]
        var shown: [String: JSON] = [:]
        for (k, v) in form { shown[k] = .string(secret.contains(k) ? "<redacted>" : v) }
        var entry: [String: JSON] = ["name": .string(name), "path": .string(path), "form": .object(shown)]
        if let v = form["variables"], let vars = try? JSON(data: Data(v.utf8)) { entry["variables"] = vars }
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let url = URL(fileURLWithPath: dir).appending(path: "\(Int(Date.now.timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(4))-\(safe).json")
        try? JSON.object(entry).data().write(to: url)
        throw IGError.http(-1, "Dry run: \(name) not sent")
    }

    /// The whole request as it would leave (creation calls and uploads): method, URL, every
    /// header (cookie values and tokens redacted), the form or JSON body, and the body size.
    nonisolated static func dryRun(_ name: String, request: URLRequest, bodySize: Int? = nil) throws {
        guard dryRunRecord(name, request: request, bodySize: bodySize) else { return }
        throw IGError.http(-1, "Dry run: \(name) not sent")
    }

    /// Writes the record; false when dry runs are off.
    @discardableResult
    nonisolated static func dryRunRecord(_ name: String, request: URLRequest, bodySize: Int? = nil) -> Bool {
        guard let dir = UserDefaults.standard.string(forKey: "IGDryRunWrites") else { return false }
        let secretHeaders: Set = ["x-csrftoken", "x-fb-lsd", "x-ig-www-claim", "x-web-session-id", "x-mid"]
        let secretFields: Set = ["fb_dtsg", "lsd", "jazoest", "av", "__hs", "__hsi", "__rev", "__spin_r", "__spin_t", "__s"]
        var headers: [String: JSON] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] {
            if k.lowercased() == "cookie" {
                headers[k] = .string(v.split(separator: ";").map { $0.split(separator: "=").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }.joined(separator: ","))
            } else {
                headers[k] = .string(secretHeaders.contains(k.lowercased()) ? "<redacted>" : v)
            }
        }
        var entry: [String: JSON] = ["name": .string(name), "method": .string(request.httpMethod ?? "GET"),
                                     "url": .string(request.url?.absoluteString ?? ""), "headers": .object(headers)]
        let body = request.httpBody ?? Data()
        entry["bodySize"] = .integer(Int64(bodySize ?? body.count))
        let type = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        if type.hasPrefix("application/x-www-form-urlencoded") {
            var form: [String: JSON] = [:]
            for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                guard let k = kv.first else { continue }
                form[k] = .string(secretFields.contains(k) ? "<redacted>" : (kv.count > 1 ? kv[1] : ""))
            }
            entry["form"] = .object(form)
        } else if type.hasPrefix("application/json") {
            var text = String(decoding: body, as: UTF8.self)
            // fb_dtsg / jazoest ride at the end of the JSON body.
            for k in ["fb_dtsg", "jazoest"] {
                text = text.replacingOccurrences(of: #""\#(k)":"[^"]*""#, with: "\"\(k)\":\"<redacted>\"", options: .regularExpression)
            }
            entry["json"] = .string(text)
        }
        let safe = name.replacingOccurrences(of: "/", with: "_")
        let url = URL(fileURLWithPath: dir).appending(path: "\(Int(Date.now.timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(4))-\(safe).json")
        try? JSON.object(entry).data().write(to: url)
        return true
    }

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
    func rest(_ method: Method, _ path: String, query: [String: String] = [:], form: [String: String]? = nil,
              headers extraHeaders: [String: String] = [:]) async throws -> JSON {
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
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        if let form {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody(form)
            #if DEBUG
            if method == .post { try Self.dryRun(comps.path, form: form, path: comps.path) }
            #endif
        }
        let json = try await send(request, path: comps.path)
        dump(comps.path.replacingOccurrences(of: "/", with: "_"), json)
        return json
    }

    /// The page's form token fields, which the web app's REST posts carry (recorded:
    /// news/inbox_seen, accounts/edit).
    func formTokens() -> [String: String] {
        page.commonForm(counter: "0", userId: nil).filter { $0.key == "fb_dtsg" || $0.key == "jazoest" }
    }

    // MARK: Transport

    /// Which of the web app's header sets a request carries.
    nonisolated enum HeaderSet: Sendable, Equatable {
        /// REST (`/api/v1/`) or GraphQL, told apart by the path.
        case standard
        /// The web app's `cometAsyncFetch` posts (recorded: post delete, reel publish): the page
        /// headers (`X-FB-LSD`, `X-IG-D`, `X-FB-Entry-Nonce`) and, when `api`, the REST ones the
        /// caller adds (`PolarisInstajax.getHeaders`), without `X-Requested-With`.
        case comet(api: Bool)
        /// instagram.com in phone mode (recorded: story publish): the mobile web app's id, five
        /// touch points and an iPhone browser.
        case mobile
    }

    func send(_ base: URLRequest, path: String, retried: Bool = false, headers set: HeaderSet = .standard,
              dryRun dryRunName: String? = nil) async throws -> JSON {
        var request = base
        guard let csrf = await session.csrfToken else { throw IGError.signedOut }
        request.setValue(await session.cookieHeader(for: "www.instagram.com"), forHTTPHeaderField: "Cookie")
        switch set {
        case .standard, .mobile:
            request.setValue(csrf, forHTTPHeaderField: "x-csrftoken")
            request.setValue(set == .mobile ? Self.mobileAppId : page.appId, forHTTPHeaderField: "x-ig-app-id")
            request.setValue(page.asbdId, forHTTPHeaderField: "x-asbd-id")
            // The web app sends these on REST calls only, not on GraphQL.
            if !path.hasSuffix("graphql") && !path.hasSuffix("/graphql/query") {
                request.setValue(wwwClaim, forHTTPHeaderField: "x-ig-www-claim")
                request.setValue("XMLHttpRequest", forHTTPHeaderField: "x-requested-with")
                // Also on the web app's REST calls (recorded): the build number and its web session id.
                if let rev = page.rev { request.setValue(rev, forHTTPHeaderField: "X-Instagram-AJAX") }
                request.setValue(page.webSessionId, forHTTPHeaderField: "X-Web-Session-ID")
            }
        case .comet(let api):
            request.setValue(page.asbdId, forHTTPHeaderField: "x-asbd-id")
            if api {
                request.setValue(csrf, forHTTPHeaderField: "x-csrftoken")
                request.setValue(page.appId, forHTTPHeaderField: "x-ig-app-id")
                request.setValue(wwwClaim, forHTTPHeaderField: "x-ig-www-claim")
                if let rev = page.rev { request.setValue(rev, forHTTPHeaderField: "X-Instagram-AJAX") }
                request.setValue(page.webSessionId, forHTTPHeaderField: "X-Web-Session-ID")
            }
            request.setValue("www", forHTTPHeaderField: "X-IG-D")
            if let lsd = page.lsd { request.setValue(lsd, forHTTPHeaderField: "X-FB-LSD") }
            if let nonce = page.entryNonce { request.setValue(nonce, forHTTPHeaderField: "X-FB-Entry-Nonce") }
        }
        request.setValue(set == .mobile ? "5" : "0", forHTTPHeaderField: "X-IG-Max-Touch-Points")
        request.setValue(set == .mobile ? Self.mobileUserAgent : Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.origin, forHTTPHeaderField: "Origin")
        request.setValue(Self.origin + "/", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        // What a browser adds to the web app's own requests; Meta's CSRF checks look for them.
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        #if DEBUG
        if let dryRunName { try Self.dryRun(dryRunName, request: request) }
        #endif

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
            return try await send(base, path: path, retried: true, headers: set, dryRun: dryRunName)
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

    func nextCounter() -> String {
        requestCounter += 1
        return String(requestCounter, radix: 36)
    }

    /// The next `client_mutation_id` (a decimal string, as the web app sends it).
    func nextMutationId() -> String {
        mutationCounter += 1
        return String(mutationCounter)
    }

    /// `input` of the web app's XIG mutations: your actor id and the mutation counter first
    /// (both strings), then the action's own fields.
    func mutationInput(_ fields: [String: JSON]) -> JSON {
        var input: [String: JSON] = ["actor_id": .string(page.actorId ?? ""), "client_mutation_id": .string(nextMutationId())]
        input.merge(fields) { $1 }
        return .object(input)
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
    /// `fb_dtsg_ag`: the token the web app's older "ajax" GETs carry (the archive).
    var asyncGetToken: String?
    /// `IGDMqttWebDeviceID.clientId`: the inbox query and the DM socket send it.
    var dmDeviceId: String?
    /// `CurrentUserInitialData.IG_USER_EIMU`: our own messaging id (DM senders are named by it).
    var messagingId: String?
    /// `DGWWebConfig.appId`: the real-time gateway's app id.
    var dgwAppId: String?
    /// `PolarisViewer.data.fbid` (also `NON_FACEBOOK_USER_ID`): the gateway's `x-dgw-uuid`.
    var viewerFbid: String?
    /// `PolarisViewer.id`: the account's user id (pk).
    var viewerId: String?
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
        dgwAppId = first(#""DGWWebConfig",\[\],\{"appId":"(\d+)""#)
        viewerFbid = first(#""PolarisViewer",\[\],\{"data":\{[^{}]*?"fbid":"(\d+)""#) ?? first(#""NON_FACEBOOK_USER_ID":"(\d+)""#)
        viewerId = first(#""PolarisViewer",\[\],\{"data":\{.*?\},"id":"(\d+)"\}"#)
        entryNonce = first(#""BootloaderConfig",\[\],\{[^}]*?"nonce":"([^"]+)""#)
        asyncGetToken = first(#""async_get_token":"([^"]+)""#)
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
