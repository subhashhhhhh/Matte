import SwiftUI

/// Who you follow, as changed in this session, shared by every Follow button (post headers,
/// likes and follower lists, the profile page) so they all agree.
@Observable
final class Follows {
    private(set) var changed: [String: Friendship] = [:]
    private(set) var busy: Set<String> = []

    /// What we know about following `user` (nil: unknown, show nothing).
    func state(_ user: User) -> Friendship? {
        if let f = changed[user.id] { return f }
        guard let following = user.following else { return nil }
        return Friendship(following: following, followedBy: false, requested: user.requested ?? false)
    }

    func record(_ f: Friendship, for userId: String) { changed[userId] = f }

    func set(_ follow: Bool, user: User, client: IGClient, app: AppModel?) {
        guard !busy.contains(user.id) else { return }
        let before = state(user)
        busy.insert(user.id)
        changed[user.id] = Friendship(following: follow, followedBy: before?.followedBy ?? false, requested: false)
        Task {
            defer { busy.remove(user.id) }
            do {
                changed[user.id] = try await client.setFollowing(follow, userId: user.id)
            } catch {
                if let before { changed[user.id] = before } else { changed[user.id] = nil }
                app?.report(error)
            }
        }
    }
}

/// "Follow" beside a name, as Instagram shows it on posts by people you don't follow (and on
/// people in lists). Once followed it reads "Following"; clicking that asks once more, then
/// unfollows. Hidden for yourself and when it isn't known whether you follow them.
struct FollowChip: View {
    let user: User
    /// A button (lists) rather than a word after a name (post headers).
    var button = false
    /// Post headers: only "Follow" (and what you changed here), never "Following" for people
    /// you already followed.
    var onlyToFollow = true
    @Environment(AppModel.self) private var app
    @State private var confirming = false
    @State private var shownFollowing = false

    var body: some View {
        if user.id != app.viewerId, let follows = app.follows, let f = follows.state(user),
           !onlyToFollow || !f.following && !f.requested || shownFollowing {
            let on = f.following || f.requested
            Group {
                if button {
                    Button(action: tap) { Text(label(f)) }
                        .buttonStyle(on ? AnyButtonStyle(SecondaryPillStyle()) : AnyButtonStyle(ProminentButtonStyle(compact: true)))
                } else {
                    Button(action: tap) {
                        Text(label(f))
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(confirming ? Theme.like : on ? Color.secondary : Theme.link)
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(follows.busy.contains(user.id))
            .help(confirming ? "Click again to confirm" : on ? "Unfollow" : "Follow \(user.username)")
            .onChange(of: on) { if on { shownFollowing = true } }
            .animation(.easeOut(duration: 0.12), value: confirming)
        }
    }

    private func label(_ f: Friendship) -> String {
        if confirming { return f.requested ? "Cancel request" : "Unfollow" }
        if f.requested { return "Requested" }
        if f.following { return "Following" }
        return f.followedBy ? "Follow back" : "Follow"
    }

    private func tap() {
        guard let follows = app.follows, let client = app.client, let f = follows.state(user) else { return }
        if f.following || f.requested {
            guard confirming else {
                confirming = true
                Task { try? await Task.sleep(for: .seconds(4)); confirming = false }
                return
            }
            confirming = false
            follows.set(false, user: user, client: client, app: app)
        } else {
            follows.set(true, user: user, client: client, app: app)
        }
    }
}

/// Picks one of two button styles at run time.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
