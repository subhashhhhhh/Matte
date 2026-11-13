import SwiftUI
import AppKit

/// What you set in Settings, kept in UserDefaults (`pref.*`) and read wherever it matters
/// (one shared instance, so models and views see the same values).
@Observable
final class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// Which page Matte opens on.
    enum StartPage: String, CaseIterable, Identifiable {
        case last, home, messages, reels
        var id: String { rawValue }
        var title: String { self == .last ? "Where I left off" : rawValue.capitalized }
    }

    /// Which home feed opens.
    enum StartFeed: String, CaseIterable, Identifiable {
        case last, forYou = "home", following, favorites
        var id: String { rawValue }
        var title: String {
            switch self {
            case .last: "The one I used last"
            case .forYou: "For you"
            case .following: "Following"
            case .favorites: "Favorites"
            }
        }
    }

    enum DownloadPlace: String, CaseIterable, Identifiable {
        case downloads, ask, folder
        var id: String { rawValue }
    }

    private init() {
        func string<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            UserDefaults.standard.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? fallback }
        appearance = string("pref.appearance", Appearance.system)
        startPage = string("pref.startPage", StartPage.last)
        startFeed = string("pref.startFeed", StartFeed.last)
        hideSuggested = bool("pref.hideSuggested", false)
        startMuted = bool("pref.startMuted", false)
        hoverPreviews = bool("pref.hoverPreviews", true)
        miniPlayer = bool("pref.miniPlayer", true)
        notifications = bool("pref.notifications", true)
        notificationPreviews = bool("pref.notificationPreviews", true)
        notificationSound = bool("pref.notificationSound", true)
        dockBadge = bool("pref.dockBadge", true)
        ghostStories = bool("pref.ghostStories", false)
        ghostReadReceipts = bool("pref.ghostReadReceipts", false)
        ghostTyping = bool("pref.ghostTyping", false)
        downloadPlace = string("pref.downloadPlace", DownloadPlace.downloads)
        checkUpdates = bool("pref.checkUpdates", true)
        downloadFolder = UserDefaults.standard.string(forKey: "pref.downloadFolder")
    }

    // MARK: General

    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "pref.appearance"); applyAppearance() } }
    var startPage: StartPage { didSet { defaults.set(startPage.rawValue, forKey: "pref.startPage") } }

    /// Light, dark, or the Mac's setting, for the whole app.
    func applyAppearance() {
        NSApp?.appearance = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    // MARK: Feed

    var startFeed: StartFeed { didSet { defaults.set(startFeed.rawValue, forKey: "pref.startFeed") } }
    /// Leave out the posts Instagram mixes into For you from people you don't follow.
    var hideSuggested: Bool { didSet { defaults.set(hideSuggested, forKey: "pref.hideSuggested") } }

    // MARK: Playback

    /// Videos and songs start muted (the sound button still turns them on).
    var startMuted: Bool { didSet { defaults.set(startMuted, forKey: "pref.startMuted") } }
    /// Resting on a post plays its video or song.
    var hoverPreviews: Bool { didSet { defaults.set(hoverPreviews, forKey: "pref.hoverPreviews") } }
    /// A post you leave keeps playing in the corner.
    var miniPlayer: Bool { didSet { defaults.set(miniPlayer, forKey: "pref.miniPlayer") } }

    // MARK: Notifications

    var notifications: Bool { didSet { defaults.set(notifications, forKey: "pref.notifications") } }
    /// Show the message itself (off: just who it's from).
    var notificationPreviews: Bool { didSet { defaults.set(notificationPreviews, forKey: "pref.notificationPreviews") } }
    var notificationSound: Bool { didSet { defaults.set(notificationSound, forKey: "pref.notificationSound") } }
    var dockBadge: Bool { didSet { defaults.set(dockBadge, forKey: "pref.dockBadge") } }

    // MARK: Ghost mode

    /// Watch stories without them being marked seen.
    var ghostStories: Bool { didSet { defaults.set(ghostStories, forKey: "pref.ghostStories") } }
    /// Read messages without sending "Seen".
    var ghostReadReceipts: Bool { didSet { defaults.set(ghostReadReceipts, forKey: "pref.ghostReadReceipts") } }
    /// Type without showing "typing…".
    var ghostTyping: Bool { didSet { defaults.set(ghostTyping, forKey: "pref.ghostTyping") } }

    /// All three on (the master switch).
    var ghostMode: Bool {
        get { ghostStories && ghostReadReceipts && ghostTyping }
        set { ghostStories = newValue; ghostReadReceipts = newValue; ghostTyping = newValue }
    }

    // MARK: Updates

    /// Look for a new Matte once a day (Settings › About).
    var checkUpdates: Bool { didSet { defaults.set(checkUpdates, forKey: "pref.checkUpdates") } }

    // MARK: Downloads

    var downloadPlace: DownloadPlace { didSet { defaults.set(downloadPlace.rawValue, forKey: "pref.downloadPlace") } }
    /// The chosen folder (`downloadPlace == .folder`).
    var downloadFolder: String? { didSet { defaults.set(downloadFolder, forKey: "pref.downloadFolder") } }

    /// Where a download goes without asking: the chosen folder, else ~/Downloads.
    var downloadDirectory: URL {
        if downloadPlace == .folder, let downloadFolder { return URL(fileURLWithPath: downloadFolder, isDirectory: true) }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// "Downloads" or the folder's name, for "Saved to …".
    var downloadPlaceName: String { downloadPlace == .folder ? downloadDirectory.lastPathComponent : "Downloads" }
}
