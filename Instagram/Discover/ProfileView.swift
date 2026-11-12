import SwiftUI

/// Someone's page: a wide header (avatar, counts, bio) over a grid of their posts.
struct ProfileView: View {
    let model: ProfileModel
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                    .frame(maxWidth: 1000)
                Rectangle().fill(Theme.hairline).frame(height: 1).frame(maxWidth: 1000)
                if model.profile?.isPrivate == true, model.profile?.following != true, user.id != app.viewerId {
                    EmptyState(symbol: "lock", title: "This account is private",
                               message: "Follow them on Instagram to see their posts.")
                        .frame(height: 260)
                } else {
                    MediaGrid(browser: model.browser, minTile: 200)
                        .frame(maxWidth: 1000)
                    if model.isLoading { Spinner().padding(20) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .overlay { BrowserLightbox(browser: model.browser) }
        .animation(.easeOut(duration: 0.16), value: model.browser.opened == nil)
        .task { await model.start() }
    }

    private var user: User { model.profile?.user ?? model.user }

    private var header: some View {
        HStack(alignment: .top, spacing: 40) {
            avatar
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Text(user.username).font(.system(size: 22, weight: .semibold)).textSelection(.enabled)
                    if user.isVerified { VerifiedBadge(size: 16) }
                    Spacer(minLength: 12)
                    actions
                }
                if let p = model.profile {
                    HStack(spacing: 28) {
                        stat(p.postCount, "posts")
                        stat(p.followerCount, "followers")
                        stat(p.followingCount, "following")
                    }
                } else if !model.failed {
                    Spinner(size: 14)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if !user.fullName.isEmpty {
                        Text(user.fullName).font(.system(size: 14, weight: .semibold))
                    }
                    if let category = model.profile?.category {
                        Text(category).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    if let bio = model.profile?.biography {
                        Text(bio).font(.system(size: 14)).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let url = model.profile?.externalURL {
                        Button { NSWorkspace.shared.open(url) } label: {
                            Label(url.host() ?? url.absoluteString, systemImage: "link")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.link)
                        }
                        .buttonStyle(.plain)
                    }
                    if let p = model.profile, p.followedBy {
                        Text("Follows you").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 8)
    }

    private var avatar: some View {
        let hasStory = user.latestStory != nil
        return Button {
            if hasStory { app.openStories([StoryReel(id: user.id, user: user, seen: false)], at: 0) }
        } label: {
            Group {
                if hasStory {
                    StoryRing(seen: false, lineWidth: 3) { Avatar(url: model.profile?.hdAvatar ?? user.avatar, size: 150) }
                } else {
                    Avatar(url: model.profile?.hdAvatar ?? user.avatar, size: 150).padding(5)
                }
            }
        }
        .buttonStyle(.pressable)
        .disabled(!hasStory)
        .help(hasStory ? "View story" : "")
    }

    @ViewBuilder
    private var actions: some View {
        if let p = model.profile, user.id != app.viewerId {
            Text(p.following ? "Following" : "Not following")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.panel))
                .foregroundStyle(p.following ? .primary : .secondary)
        }
        if let thread = app.inbox?.threads.first(where: { !$0.isGroup && $0.users.first?.id == user.id }) {
            Button {
                app.openChat(thread.id)
            } label: {
                Text("Message").font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.selected))
            }
            .buttonStyle(.pressable)
        }
        if let url = URL(string: "https://www.instagram.com/\(user.username)/") {
            ChromeButton("Open on Instagram", symbol: "arrow.up.right") { NSWorkspace.shared.open(url) }
        }
    }

    private func stat(_ n: Int?, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(n.map { $0 >= 10_000 ? $0.compact : $0.formatted() } ?? "–").font(.system(size: 15, weight: .semibold))
            Text(label).font(.system(size: 15)).foregroundStyle(.secondary)
        }
    }
}

/// Makes an avatar or username open that person's profile.
private struct OpensProfile: ViewModifier {
    let user: User?
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { if let user { app.openProfile(user) } }
            .onHover { inside in
                guard user != nil else { return }
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

extension View {
    func opensProfile(_ user: User?) -> some View { modifier(OpensProfile(user: user)) }
}
