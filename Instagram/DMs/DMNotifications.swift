import AppKit
import UserNotifications
import OSLog

/// macOS notifications for new direct messages, and the unread count on the Dock icon.
/// Clicking a notification opens its chat.
final class DMNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DMNotifier()

    /// Opens a chat by thread id (set by the inbox).
    var open: ((String) -> Void)?
    private var authorized: Bool?
    private let log = Logger(subsystem: "com.subhash.Matte", category: "Notifications")

    private var center: UNUserNotificationCenter? {
        // Notifications need a real app bundle (not a bare binary or a test host).
        Bundle.main.bundleIdentifier == nil || Bundle.main.bundleURL.pathExtension != "app" ? nil : .current()
    }

    /// Becomes the notification delegate and asks for permission (the system asks only once).
    func start() {
        guard let center else { return }
        center.delegate = self
        Task {
            do {
                authorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                authorized = false
                log.info("Notifications not allowed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Posts a notification for `message` in `thread` (`sender` for groups).
    func notify(thread: DMThread, message: DMMessage, sender: User?) {
        let prefs = Preferences.shared
        guard let center, authorized != false, prefs.notifications else { return }
        let content = UNMutableNotificationContent()
        if thread.isGroup {
            content.title = thread.title
            content.subtitle = sender.map { $0.username } ?? ""
        } else {
            content.title = sender?.username ?? thread.title
        }
        content.body = prefs.notificationPreviews ? Self.preview(message) : "New message"
        content.sound = prefs.notificationSound ? .default : nil
        content.threadIdentifier = thread.id
        content.userInfo = ["thread": thread.id]
        let request = UNNotificationRequest(identifier: "dm-\(message.id)", content: content, trigger: nil)
        center.add(request) { [log] error in
            if let error { log.error("Notification failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// Removes a chat's notifications (once it's opened).
    func clear(thread: String) {
        guard let center else { return }
        center.getDeliveredNotifications { notes in
            let ids = notes.filter { $0.request.content.threadIdentifier == thread }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    #if DEBUG
    func logDelivered() {
        guard let center else { log.info("Notifications: no center"); return }
        center.getNotificationSettings { [log] s in
            center.getDeliveredNotifications { notes in
                log.info("Notifications: authorization \(s.authorizationStatus.rawValue), delivered \(notes.count)")
            }
        }
    }
    #endif

    /// The unread chat count on the Dock icon (nothing at zero).
    static func setBadge(_ count: Int) {
        let label = count > 0 && Preferences.shared.dockBadge ? String(count) : nil
        if NSApp?.dockTile.badgeLabel != label { NSApp?.dockTile.badgeLabel = label }
    }

    static func preview(_ m: DMMessage) -> String {
        switch m.body {
        case .text(let t): t
        case .media(let a):
            switch a.first?.kind {
            case .video: "Sent a video"
            case .audio: "Sent a voice message"
            case .gif: "Sent a GIF"
            case .sticker: "Sent a sticker"
            default: a.count > 1 ? "Sent \(a.count) photos" : "Sent a photo"
            }
        case .share(_, let text): text ?? "Shared a post"
        default: m.previewText
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        // The inbox only posts what should be seen (not the chat you're looking at).
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let thread = response.notification.request.content.userInfo["thread"] as? String else { return }
        await MainActor.run {
            NSApp.activate()
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            DMNotifier.shared.open?(thread)
        }
    }
}
