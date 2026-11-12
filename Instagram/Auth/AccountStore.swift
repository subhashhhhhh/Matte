import Foundation
import OSLog

/// One signed-in account, as the switcher shows it (no secrets: the cookies live elsewhere).
nonisolated struct AccountSummary: Codable, Hashable, Sendable, Identifiable {
    /// `ds_user_id`.
    var id: String
    var username: String
    var fullName: String = ""
    var avatar: URL?

    init(id: String, username: String = "", fullName: String = "", avatar: URL? = nil) {
        self.id = id; self.username = username; self.fullName = fullName; self.avatar = avatar
    }

    init(_ user: User) { self.init(id: user.id, username: user.username, fullName: user.fullName, avatar: user.avatar) }

    /// "@name", or the id until the profile has loaded once.
    var handle: String { username.isEmpty ? "Account \(id)" : "@" + username }
}

/// Every account signed in on this Mac. The current one's cookies are `session.json` (as with a
/// single account); the others wait in `accounts/<ds_user_id>.json` (0600, folder 0700) until
/// you switch to them. `accounts.json` lists all of them in the switcher's order, with only the
/// names and avatar links.
///
/// A crash between parking one account and making another current can leave an account in both
/// places: `session.json` wins and the parked copy is deleted (`dropParked`) on the next start.
nonisolated struct AccountStore: Sendable {
    static let shared = AccountStore(directory: SessionStore.directory)

    let directory: URL

    var indexURL: URL { directory.appending(path: "accounts.json") }
    var parkedDirectory: URL { directory.appending(path: "accounts", directoryHint: .isDirectory) }

    /// The parked session of `id` (a session store of its own, so it's written the same way).
    func parked(_ id: String) -> SessionStore? {
        guard Self.isValid(id) else { return nil }
        return SessionStore(url: parkedDirectory.appending(path: id + ".json"))
    }

    static func isValid(_ id: String) -> Bool { !id.isEmpty && id.count <= 30 && id.allSatisfy(\.isNumber) }

    // MARK: The list

    func list() -> [AccountSummary] {
        guard let data = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([AccountSummary].self, from: data) else { return [] }
        var seen = Set<String>()
        return list.filter { Self.isValid($0.id) && seen.insert($0.id).inserted }
    }

    func saveList(_ list: [AccountSummary]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        do {
            try data.write(to: indexURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        } catch {
            Logger(subsystem: "com.subhash.Instagram", category: "Accounts").error("Account list save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Adds `account` (at the end) or refreshes its name and avatar (in place).
    @discardableResult
    func upsert(_ account: AccountSummary) -> [AccountSummary] {
        var list = list()
        if let i = list.firstIndex(where: { $0.id == account.id }) {
            var merged = account
            // A summary made before the profile loaded mustn't wipe the name we had.
            if merged.username.isEmpty { merged = list[i] }
            list[i] = merged
        } else {
            list.append(account)
        }
        saveList(list)
        return list
    }

    @discardableResult
    func remove(_ id: String) -> [AccountSummary] {
        dropParked(id)
        let list = list().filter { $0.id != id }
        saveList(list)
        return list
    }

    // MARK: Parked sessions

    /// Puts `cookies` aside for `id` until it's switched to.
    func park(_ cookies: [StoredCookie], for id: String) {
        guard let store = parked(id) else { return }
        try? FileManager.default.createDirectory(at: parkedDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        store.save(cookies)
    }

    /// The parked cookies of `id`, if they still make a signed-in session.
    func unpark(_ id: String) -> [StoredCookie]? {
        guard let saved = parked(id)?.load(), IGSession.isSignedIn(saved) else { return nil }
        return saved
    }

    func dropParked(_ id: String) { parked(id)?.clear() }

    /// Accounts other than `current` that can be switched to (listed and with a live parked session).
    func others(than current: String?) -> [AccountSummary] {
        list().filter { $0.id != current && unpark($0.id) != nil }
    }

    /// Removes the list and every parked session (tests).
    func wipe() {
        try? FileManager.default.removeItem(at: parkedDirectory)
        try? FileManager.default.removeItem(at: indexURL)
    }
}
