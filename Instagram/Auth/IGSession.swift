import Foundation
import OSLog

/// A cookie in a Codable, Sendable form we fully control.
nonisolated struct StoredCookie: Codable, Hashable, Sendable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?
    var secure: Bool
    var httpOnly: Bool

    init(_ c: HTTPCookie) {
        name = c.name; value = c.value; domain = c.domain; path = c.path
        expires = c.expiresDate; secure = c.isSecure; httpOnly = c.isHTTPOnly
    }

    var isExpired: Bool { expires.map { $0 < .now } ?? false }

    /// RFC 6265 domain matching: ".instagram.com" matches "www.instagram.com".
    func matches(host: String) -> Bool {
        let d = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == d || host.hasSuffix("." + d)
    }

    /// Identity used to replace a cookie when Instagram rotates it.
    var key: String { "\(name)|\(domain.hasPrefix(".") ? String(domain.dropFirst()) : domain)|\(path)" }
}

/// The signed-in Instagram session: the cookies from the login sheet. `sessionid` is the
/// session itself; `csrftoken` is sent back as `x-csrftoken` on every request; `ds_user_id`
/// is the account's numeric id.
actor IGSession {
    private var cookies: [String: StoredCookie]
    private let store: SessionStore
    private let log = Logger(subsystem: "com.subhash.Instagram", category: "Session")
    private var saveTask: Task<Void, Never>?
    /// Signed out: nothing may write this session to disk again.
    private var ended = false

    init(cookies: [StoredCookie], store: SessionStore = .shared) {
        self.cookies = Dictionary(cookies.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
        self.store = store
    }

    nonisolated static func isSignedIn(_ cookies: [StoredCookie]) -> Bool {
        let names = Set(cookies.filter { !$0.isExpired }.map(\.name))
        return names.contains("sessionid") && names.contains("csrftoken") && names.contains("ds_user_id")
    }

    /// Restores the saved session, if any.
    static func restore(store: SessionStore = .shared) -> IGSession? {
        guard let saved = store.load(), isSignedIn(saved) else { return nil }
        return IGSession(cookies: saved, store: store)
    }

    func save() {
        guard !ended else { return }
        store.save(Array(cookies.values))
    }

    /// Signing out: cancels a save still waiting (from rotated cookies) and refuses later
    /// ones, which would otherwise write the session back after the file was deleted.
    func end() {
        ended = true
        saveTask?.cancel()
        saveTask = nil
    }

    /// The CSRF token. Instagram rotates it now and then through Set-Cookie (see `absorb`).
    var csrfToken: String? { cookies.values.first { $0.name == "csrftoken" && !$0.isExpired }?.value }

    /// The signed-in account's numeric id.
    var userId: String? { cookies.values.first { $0.name == "ds_user_id" && !$0.isExpired }?.value }

    /// A cookie by name (for values the web app sends back in headers, like `mid` or `rur`).
    func cookie(_ name: String) -> String? { cookies.values.first { $0.name == name && !$0.isExpired }?.value }

    /// Every live cookie (the DM socket sends them all on connect).
    var allCookies: [StoredCookie] { cookies.values.filter { !$0.isExpired } }

    func cookieHeader(for host: String) -> String {
        cookies.values
            .filter { !$0.isExpired && $0.matches(host: host) }
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// Takes in rotated cookies (`csrftoken`, `rur` and friends) from a response.
    func absorb(responseHeaders: [String: String], url: URL) {
        let fresh = HTTPCookie.cookies(withResponseHeaderFields: responseHeaders, for: url)
        guard !fresh.isEmpty else { return }
        var changed = false
        for c in fresh.map(StoredCookie.init) {
            if c.isExpired {
                changed = cookies.removeValue(forKey: c.key) != nil || changed
            } else if cookies[c.key]?.value != c.value {
                cookies[c.key] = c
                changed = true
            }
        }
        guard changed else { return }
        log.debug("Absorbed \(fresh.count) rotated cookie(s)")
        // Coalesce bursts of responses into one disk write.
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.save()
        }
    }
}

/// Persists session cookies to a user-only (0600) file in Application Support, the way
/// browsers keep their cookie jars. Not the keychain: a self-signed app has no team ID, so a
/// keychain item admits only the exact build that wrote it, and every update would ask for
/// the login password.
nonisolated struct SessionStore: Sendable {
    static let shared = SessionStore()

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "com.subhash.Instagram", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }()

    var url: URL { Self.directory.appending(path: "session.json") }

    func load() -> [StoredCookie]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([StoredCookie].self, from: data)
    }

    func save(_ cookies: [StoredCookie]) {
        guard let data = try? JSONEncoder().encode(cookies) else { return }
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Logger(subsystem: "com.subhash.Instagram", category: "Session").error("Session save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func clear() { try? FileManager.default.removeItem(at: url) }
}
