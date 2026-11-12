import SwiftUI

/// Someone's page: a wide header (avatar, counts, bio), their highlights, and tabs of grids
/// (Posts, Reels, Tagged, and Saved on your own page).
struct ProfileView: View {
    @State private var flight = PhotoFlight()
    @State private var editing = false
    let model: ProfileModel
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                    .frame(maxWidth: 1200)
                if !model.highlights.isEmpty, !model.isLocked {
                    HighlightsRow(highlights: model.highlights) { model.openHighlight($0) }
                        .frame(maxWidth: 1200)
                }
                if model.isLocked {
                    Rectangle().fill(Theme.hairline).frame(height: 1).frame(maxWidth: 1200)
                    EmptyState(symbol: "lock", title: "This account is private",
                               message: model.profile?.requested == true
                                   ? "Your follow request is waiting."
                                   : "Follow them to see their posts.")
                        .frame(height: 260)
                } else {
                    ProfileTabBar(tabs: model.tabs, selection: Binding(get: { model.tab }, set: { model.tab = $0 }))
                        .frame(maxWidth: 1200)
                    if model.tab == .saved, !model.collections.isEmpty {
                        CollectionChips(collections: model.collections, selected: model.collectionId) { model.selectCollection($0) }
                            .frame(maxWidth: 1200)
                    }
                    // Always 3 across: accounts design their grids for it (multi-post pictures).
                    FeedGrid(feed: model.activeFeed, empty: emptyText, columns: 3)
                        .frame(maxWidth: 1200)
                        .id(model.tab.rawValue + (model.collectionId ?? ""))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 60 } action: { model.posts.browser.scrolledAway = $1 }
        .overlay { BrowserLightbox(browser: model.activeFeed.browser) }
        .photoFlightHost(flight)
        .overlay {
            if editing {
                EditProfileSheet(onSaved: { Task { await model.loadHeader() } }, onClose: { editing = false })
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: editing)
        #if DEBUG
        // `-IGEditProfile YES`: open the edit form on your own profile (it only loads; nothing is saved).
        .task {
            if UserDefaults.standard.bool(forKey: "IGEditProfile") {
                while model.profile == nil { try? await Task.sleep(for: .milliseconds(200)) }
                if model.isMe { editing = true }
            }
        }
        #endif
        .overlay {
            if let list = model.followList {
                FollowListPanel(model: list) { model.followList = nil }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.16), value: model.followList == nil)
        .task { await model.start() }
    }

    private var user: User { model.profile?.user ?? model.user }

    private var emptyText: (symbol: String, title: String) {
        switch model.tab {
        case .posts: ("camera", "No posts yet")
        case .reels: ("play.rectangle", "No reels yet")
        case .reposts: ("arrow.2.squarepath", model.isMe ? "Posts you repost show up here" : "No reposts yet")
        case .tagged: ("person.crop.square", "No photos of \(user.username)")
        case .saved: ("bookmark", "Nothing saved yet")
        }
    }

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
                        stat(p.postCount, "posts", action: nil)
                        stat(p.followerCount, p.followerCount == 1 ? "follower" : "followers",
                             action: model.isLocked ? nil : { model.openFollowList(followers: true) })
                        stat(p.followingCount, "following",
                             action: model.isLocked ? nil : { model.openFollowList(followers: false) })
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
        if let p = model.profile, !model.isMe {
            FollowButton(profile: p, confirming: model.confirmingUnfollow, busy: model.followBusy) { model.followTapped() }
        }
        if model.isMe {
            Button("Edit profile") { editing = true }
                .buttonStyle(.secondaryPill)
            Button("Archive") { app.openArchive() }
                .buttonStyle(.secondaryPill)
        }
        if let thread = app.inbox?.threads.first(where: { !$0.isGroup && $0.users.first?.id == user.id }) {
            Button("Message") { app.openChat(thread.id) }
                .buttonStyle(.secondaryPill)
        }
        if let url = URL(string: "https://www.instagram.com/\(user.username)/") {
            ChromeButton("Open on Instagram", symbol: "arrow.up.right") { NSWorkspace.shared.open(url) }
        }
    }

    @ViewBuilder
    private func stat(_ n: Int?, _ label: String, action: (() -> Void)?) -> some View {
        let text = HStack(spacing: 4) {
            Text(n.map { $0 >= 10_000 ? $0.compact : $0.formatted() } ?? "–").font(.system(size: 15, weight: .semibold))
            Text(label).font(.system(size: 15)).foregroundStyle(.secondary)
        }
        if let action {
            Button(action: action) { text }
                .buttonStyle(.pressable)
                .pointingHand()
        } else {
            text
        }
    }
}

/// Follow / Following / Requested, asking once more before unfollowing.
private struct FollowButton: View {
    let profile: Profile
    let confirming: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if profile.following || profile.requested {
                Button(action: action) {
                    Text(confirming ? (profile.requested ? "Cancel request" : "Unfollow")
                                    : profile.requested ? "Requested" : "Following")
                        .foregroundStyle(confirming ? Theme.like : .primary)
                        .contentTransition(.opacity)
                }
                .buttonStyle(.secondaryPill)
                .help(confirming ? "Click again to confirm" : profile.requested ? "Cancel your follow request" : "Unfollow")
            } else {
                Button(profile.followedBy ? "Follow back" : "Follow", action: action)
                    .buttonStyle(.prominentCompact)
            }
        }
        .disabled(busy)
        .animation(.easeOut(duration: 0.12), value: confirming)
    }
}

// MARK: - Highlights

/// Story highlights: round covers with titles, scrolling sideways.
struct HighlightsRow: View {
    let highlights: [Highlight]
    let open: (Highlight) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 22) {
                ForEach(highlights) { h in
                    Button { open(h) } label: {
                        VStack(spacing: 7) {
                            RemoteImage(url: h.cover, contentMode: .fill)
                                .frame(width: 74, height: 74)
                                .clipShape(Circle())
                                .padding(4)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.16), lineWidth: 1))
                            Text(h.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .frame(maxWidth: 86)
                        }
                    }
                    .buttonStyle(.pressable)
                    .pointingHand()
                    .help(h.title)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Tabs

/// Instagram's profile tabs: icon and small caps label, a line over the selected one.
struct ProfileTabBar: View {
    let tabs: [ProfileTab]
    @Binding var selection: ProfileTab
    @Namespace private var line

    var body: some View {
        HStack(spacing: 56) {
            ForEach(tabs) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    HStack(spacing: 6) {
                        icon(tab, selected: selected)
                        Text(tab.title.uppercased())
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(1)
                    }
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(height: 46)
                    .overlay(alignment: .top) {
                        if selected {
                            Rectangle().fill(.primary).frame(height: 1)
                                .matchedGeometryEffect(id: "line", in: line)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHand()
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .animation(Motion.slide, value: selection)
    }

    @ViewBuilder
    private func icon(_ tab: ProfileTab, selected: Bool) -> some View {
        switch tab {
        case .posts: Image(systemName: "square.grid.3x3").font(.system(size: 12, weight: .semibold))
        case .reels: IGGlyph(icon: selected ? .reelsFilled : .reels, size: 13)
        case .reposts: IGGlyph(icon: .repost, size: 13)
        case .tagged: Image(systemName: "person.crop.square").font(.system(size: 12, weight: .semibold))
        case .saved: IGGlyph(icon: selected ? .saveFilled : .save, size: 13)
        }
    }
}

/// Saved-post collections as pills ("All posts" first).
private struct CollectionChips: View {
    let collections: [SavedCollection]
    let selected: String?
    let select: (String?) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                chip("All posts", id: nil)
                ForEach(collections) { c in chip(c.name, id: c.id) }
            }
        }
        .scrollIndicators(.never)
    }

    private func chip(_ title: String, id: String?) -> some View {
        let on = selected == id
        return Button { select(id) } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .foregroundStyle(on ? Theme.background : .primary)
                .background(Capsule().fill(on ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(0.07))))
                .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
    }
}

/// A paged grid with its loading, empty and failed states.
struct FeedGrid: View {
    let feed: MediaFeed
    var empty: (symbol: String, title: String)
    var minTile: CGFloat = 200
    var columns: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            if feed.isEmpty {
                if feed.failed {
                    EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't load this", actionTitle: "Try Again") {
                        Task { await feed.retry() }
                    }
                    .frame(height: 260)
                } else {
                    EmptyState(symbol: empty.symbol, title: empty.title).frame(height: 260)
                }
            } else {
                MediaGrid(browser: feed.browser, minTile: minTile, columns: columns)
                if feed.isLoading { Spinner().padding(20) }
            }
        }
        .task { await feed.loadIfNeeded() }
    }
}

// MARK: - Small helpers

extension View {
    /// The pointing-hand cursor while hovering.
    func pointingHand() -> some View {
        onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
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
