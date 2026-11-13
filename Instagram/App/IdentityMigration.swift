import Foundation

/// Matte was called `com.subhash.Instagram` until 1.0. On the first launch as `com.subhash.Matte`,
/// what the old identity kept moves over, so nobody is signed out or loses their settings: the
/// saved logins and accounts (Application Support), the caches, and the preferences.
enum IdentityMigration {
    static let old = "com.subhash.Instagram"
    static let new = "com.subhash.Matte"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromInstagramIdentity") else { return }
        let fm = FileManager.default
        for base in [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory] {
            guard let root = fm.urls(for: base, in: .userDomainMask).first else { continue }
            let from = root.appending(path: old, directoryHint: .isDirectory)
            let to = root.appending(path: new, directoryHint: .isDirectory)
            // Only into a fresh place: never over what Matte already has.
            if fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }
        // The old app's preferences (only its own keys, not the global ones).
        if let keys = CFPreferencesCopyKeyList(old as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] {
            for key in keys where defaults.object(forKey: key) == nil {
                if let value = CFPreferencesCopyAppValue(key as CFString, old as CFString) { defaults.set(value, forKey: key) }
            }
        }
        defaults.set(true, forKey: "migratedFromInstagramIdentity")
    }
}
