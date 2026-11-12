import Foundation
import OSLog

/// The last good result of each page's first load, on disk, so a launch (or a revisit) shows
/// content at once while the fresh copy loads.
///
/// Holds parsed models, never raw responses: small JSON files in
/// `~/Library/Caches/com.subhash.Instagram/data/<ds_user_id>/`, one per page (`feed-home`,
/// `tray`, `reels`, `explore`, `inbox`, `profile-<id>`), each list capped by its caller.
/// Reads are synchronous (a few KB, on first show); writes go to one background queue.
/// Anything that doesn't decode (an older shape of the models) is a miss and is deleted.
///
/// Cached results are stale by definition: they show what was there, but their cursors are
/// gone. Models treat them as a placeholder for page 1 and fetch page 1 before paging on.
nonisolated final class ResponseCache: @unchecked Sendable {
    /// Bump when a cached shape changes in a way old files must not be read as.
    static let schema = 1

    /// Off in unit tests (they build models against stubbed responses); tests may turn it on.
    nonisolated(unsafe) static var isEnabled = !InboxModel.isTesting

    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "com.subhash.Instagram/data", directoryHint: .isDirectory)
    }

    /// One queue for every account: a sign-out's wipe lands after any write queued before it.
    private static let queue = DispatchQueue(label: "com.subhash.Instagram.ResponseCache", qos: .utility)
    private static let log = Logger(subsystem: "com.subhash.Instagram", category: "Cache")

    let directory: URL
    private let lock = NSLock()
    private var ended = false

    /// Nil when caching is off or there's no account to key it by.
    init?(account: String?, root: URL = ResponseCache.root) {
        guard Self.isEnabled, let account, !account.isEmpty, account.allSatisfy(\.isNumber) else { return nil }
        directory = root.appending(path: account, directoryHint: .isDirectory)
    }

    struct Entry<T> {
        var value: T
        var savedAt: Date
    }

    private struct Envelope<T: Codable>: Codable {
        var schema: Int
        var savedAt: Date
        var value: T
    }

    /// The saved value for `key`, if there is one younger than `maxAge` that still decodes.
    func load<T: Codable>(_ type: T.Type, _ key: String, maxAge: TimeInterval = 7 * 86_400) -> Entry<T>? {
        guard !isEnded else { return nil }
        let url = file(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data), envelope.schema == Self.schema,
              Date.now.timeIntervalSince(envelope.savedAt) < maxAge else {
            Self.queue.async { try? FileManager.default.removeItem(at: url) }
            return nil
        }
        return Entry(value: envelope.value, savedAt: envelope.savedAt)
    }

    /// Writes `value` for `key` in the background (the newest write wins).
    func save<T: Codable & Sendable>(_ value: T, _ key: String) {
        let url = file(key), directory = directory
        Self.queue.async { [self] in
            guard !isEnded else { return }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(Envelope(schema: Self.schema, savedAt: .now, value: value))
                try data.write(to: url, options: [.atomic])
            } catch {
                Self.log.error("Cache write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func remove(_ key: String) {
        let url = file(key)
        Self.queue.async { try? FileManager.default.removeItem(at: url) }
    }

    /// Marks `key` as just used (for `trim`, which keeps the most recently used).
    func touch(_ key: String) {
        let url = file(key)
        Self.queue.async { try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path) }
    }

    /// Keeps only the `keep` most recently used files whose key starts with `prefix`.
    func trim(prefix: String, keep: Int) {
        let directory = directory
        Self.queue.async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            let matching = files.filter { $0.lastPathComponent.hasPrefix(prefix) }
            guard matching.count > keep else { return }
            func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            for u in matching.sorted(by: { date($0) > date($1) }).dropFirst(keep) { try? fm.removeItem(at: u) }
        }
    }

    /// Signed out: no more reads or writes through this cache.
    func end() {
        lock.lock(); ended = true; lock.unlock()
    }

    private var isEnded: Bool {
        lock.lock(); defer { lock.unlock() }
        return ended
    }

    /// Deletes every account's cache (sign-out), after any write already queued.
    static func clearAll(root: URL = ResponseCache.root) {
        queue.async { try? FileManager.default.removeItem(at: root) }
    }

    /// Deletes one account's cache (signing out of it while other accounts stay signed in).
    static func clear(account: String, root: URL = ResponseCache.root) {
        guard AccountStore.isValid(account) else { return }
        let dir = root.appending(path: account, directoryHint: .isDirectory)
        queue.async { try? FileManager.default.removeItem(at: dir) }
    }

    /// Waits for queued writes (tests).
    static func flush() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in queue.async { c.resume() } }
    }

    func file(_ key: String) -> URL {
        let safe = String(key.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return directory.appending(path: safe + ".json")
    }
}

extension Media {
    /// Instagram signs its CDN links with an expiry (`oe`, hex Unix seconds); a cached post whose
    /// links have expired (or are about to) can't show, so it's dropped.
    var linksExpired: Bool {
        let first = children.first ?? self
        let urls = [images.first?.url ?? first.images.first?.url, videos.first?.url ?? first.videos.first?.url]
        return urls.contains { url in
            guard let url, let oe = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "oe" })?.value,
                  let seconds = Int(oe, radix: 16) else { return false }
            return Date(timeIntervalSince1970: TimeInterval(seconds)) < Date.now.addingTimeInterval(15 * 60)
        }
    }
}

extension Media {
    /// This post as a cache file keeps it: only the images `image(minWidth:)` can pick (the
    /// ones in the post's own shape; Instagram also lists square crops of each size), which
    /// halves the file.
    var forCache: Media {
        var m = self
        let shaped = images.filter { r in
            guard r.width > 0, r.height > 0, width > 1, height > 1 else { return false }
            return abs(CGFloat(r.width) / CGFloat(r.height) - aspect) <= aspect * 0.03
        }
        if !shaped.isEmpty { m.images = shaped }
        m.children = children.map(\.forCache)
        return m
    }
}

extension Array where Element == Media {
    /// What a cache file keeps of a page: the first `limit` posts with live links.
    func cacheable(_ limit: Int) -> [Media] { filter { !$0.linksExpired }.prefix(limit).map(\.forCache) }
}
