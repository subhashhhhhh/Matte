import SwiftUI

struct FeedView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.onScreen) private var onScreen
    let model: FeedModel
    @State private var flight = PhotoFlight()

    #if DEBUG
    /// `-IGScenario tabs|reopen`: replays a user's steps for screenshots (logs each step's time).
    private func runScenario() async {
        guard let name = UserDefaults.standard.string(forKey: "IGScenario") else { return }
        func step(_ s: String) { FileHandle.standardError.write(Data("SCENARIO \(Date.now.timeIntervalSince1970) \(s)\n".utf8)) }
        while model.posts.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
        try? await Task.sleep(for: .seconds(2))
        switch name {
        case "tabs":
            step("following"); model.source = .following
            try? await Task.sleep(for: .seconds(4))
            step("back"); model.source = .forYou
        case "reopen":
            step("open1"); openPost(0)
            try? await Task.sleep(for: .seconds(4))
            step("close"); model.closeOpened()
            try? await Task.sleep(for: .seconds(1.5))
            step("open2"); openPost(0)
        default: break
        }
    }
    #endif

    /// Opens a post with the photo flying out of its tile (Lumen's animation).
    private func openPost(_ i: Int) {
        let posts = model.visible
        guard posts.indices.contains(i), !flight.isFlying else { return }
        // A video previewing in its card carries on in the full post (VideoHandoff), after the flight.
        VideoHandoff.shared.expect(for: 2)
        flight.open(posts[i], to: PostLightbox.stageRect(in: flight.hostSize, media: posts[i])) {}
        model.open(at: i)
    }

    var body: some View {
        GeometryReader { geo in
            // Wide windows: stories as a column on the left, posts in as many columns as fit.
            let storiesColumn = geo.size.width >= 1000 && (!model.tray.isEmpty || app.me != nil)
            let storiesWidth: CGFloat = 76
            let gridWidth = geo.size.width - (storiesColumn ? storiesWidth : 0) - 48
            let columns = max(1, min(4, Int((gridWidth + 16) / (300 + 16))))
            let columnWidth = min(420, (gridWidth - CGFloat(columns - 1) * 16) / CGFloat(columns))
            HStack(spacing: 0) {
                if storiesColumn {
                    StoriesColumn(reels: model.tray, me: app.me,
                                  add: { app.openStoryEditor() }) { app.openStories(model.tray, at: $0) }
                        .frame(width: storiesWidth)
                        // Its hover labels reach out over the feed.
                        .zIndex(1)
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                }
                ScrollViewReader { scroller in
                ScrollView {
                    VStack(spacing: 16) {
                        if !storiesColumn, !model.tray.isEmpty || app.me != nil {
                            StoryTray(reels: model.tray, me: app.me, add: { app.openStoryEditor() }) { app.openStories(model.tray, at: $0) }
                        }
                        FeedControls(model: model)
                        Masonry(model: model, columns: columns, columnWidth: columnWidth, openPost: openPost)
                        if model.isLoadingMore { Spinner().padding(20) }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .id("feedTop")
                }
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 60 } action: { model.scrolledAway = $1 }
                .onChange(of: model.scrollToTopRequest) {
                    withAnimation(.easeOut(duration: 0.35)) { scroller.scrollTo("feedTop", anchor: .top) }
                }
                .overlay(alignment: .top) {
                    if !model.pending.isEmpty {
                        NewPostsPill(count: model.pending.count) { model.showPending() }
                            .padding(.top, 14)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.25), value: model.pending.isEmpty)
                }
            }
        }
        .overlay {
            if model.posts.isEmpty, !model.isLoading, !model.loadFailed, model.source == .favorites {
                EmptyState(symbol: "star", title: "No favorites yet",
                           message: "Add accounts to Favorites in the Instagram app and their posts show up here, newest first.")
            } else if model.posts.isEmpty, model.loadFailed {
                EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't load your feed", actionTitle: "Try Again") {
                    Task { await model.refresh() }
                }
            } else if model.posts.isEmpty, model.isLoading {
                Spinner(size: 22)
            }
        }
        .overlay {
            // Hidden while its photo is still flying in; the flight hands over when it lands.
            if let opened = model.opened, !flight.isFlying(opened.pk) {
                PostLightbox(model: opened,
                             canPrevious: (model.openedIndex ?? 0) > 0,
                             canNext: (model.openedIndex ?? 0) < model.visible.count - 1,
                             step: { model.step($0) }, close: { model.closeOpened() })
            }
        }
        .photoFlightHost(flight)
        .environment(\.prewarmPost) { model.prewarm($0) }
        .onChange(of: model.debugOpenRequest) { if let i = model.debugOpenRequest { openPost(i) } }
        #if DEBUG
        .task { await runScenario() }
        #endif
        .task { await model.loadIfNeeded() }
        // Newer posts while the feed is on screen and Matte is in front: every three minutes,
        // and soon after you come back to it (Following and Favorites; see `refreshLive`).
        .task(id: onScreen) {
            guard onScreen else { return }
            var every: TimeInterval = 180
            #if DEBUG
            // `-IGFeedRefreshSeconds N`: check that often (and log each check).
            let n = UserDefaults.standard.double(forKey: "IGFeedRefreshSeconds")
            if n > 0 { every = n }
            #endif
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(min(20, every)))
                if NSApp.isActive, Date.now.timeIntervalSince(model.lastFetched) > every { await model.refreshLive() }
            }
        }
    }
}

/// Which feed (For you / Following / Favorites), above the grid.
private struct FeedControls: View {
    @Bindable var model: FeedModel
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 8) {
            // Instagram's own feeds: ranked, everyone you follow newest first, favourites.
            HStack(spacing: 2) {
                ForEach(FeedSource.allCases) { source in
                    let on = model.source == source
                    Button { withAnimation(Motion.slide) { model.source = source } } label: {
                        Text(source.title)
                            .font(.system(size: 13, weight: on ? .semibold : .medium))
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background {
                                if on {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.selected)
                                        .matchedGeometryEffect(id: "feed-source", in: pill)
                                }
                            }
                            .foregroundStyle(on ? .primary : .secondary)
                    }
                    .buttonStyle(.pressable)
                    // A double-click reads that feed again.
                    .simultaneousGesture(TapGesture(count: 2).onEnded { Task { await model.userRefresh() } })
                    .help("Double-click to refresh")
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
            if model.refreshing { Spinner(size: 14).transition(.opacity) }
            Spacer()
        }
    }
}

/// Posts in columns of equal width, each post going to the shortest column so far (stable as
/// pages are appended: earlier posts never move).
private struct Masonry: View {
    let model: FeedModel
    let columns: Int
    let columnWidth: CGFloat
    let openPost: (Int) -> Void

    var body: some View {
        let posts = model.visible
        let lanes = layout(posts)
        HStack(alignment: .top, spacing: 16) {
            ForEach(0..<columns, id: \.self) { c in
                LazyVStack(spacing: 16) {
                    ForEach(lanes[c], id: \.self) { i in
                        let post = posts[i]
                        PostTile(post: post, width: columnWidth, isPreviewing: model.playing == post.pk,
                                 setPreviewing: { on in
                                     if on { model.playing = post.pk } else if model.playing == post.pk { model.playing = nil }
                                 },
                                 open: { openPost(i) })
                            // Keyed by the post, not its place: another feed's post at the same
                            // place is a new card (its song, hover and the rest start over).
                            .id(post.pk)
                            .onAppear {
                                if i >= posts.count - 4 { Task { await model.loadMore() } }
                            }
                    }
                }
                .frame(width: columnWidth)
            }
        }
    }

    private func layout(_ posts: [Media]) -> [[Int]] {
        var lanes = Array(repeating: [Int](), count: columns)
        var heights = Array(repeating: CGFloat(0), count: columns)
        for (i, post) in posts.enumerated() {
            let c = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            lanes[c].append(i)
            heights[c] += PostTile.estimatedHeight(post, width: columnWidth) + 16
        }
        return lanes
    }
}

/// A post opened over the grid: the media as large as the window allows, the caption and
/// comments beside it. ←/→ step through the feed, Esc closes.
struct PostLightbox: View {
    @Environment(\.photoFlight) private var flight
    @Environment(AppModel.self) private var app
    @Environment(\.onScreen) private var onScreen
    let model: MediaDetailModel
    let canPrevious: Bool
    let canNext: Bool
    let step: (Int) -> Void
    let close: () -> Void
    @FocusState private var focused: Bool
    /// The caption and comments ease in once the photo has landed.
    @State private var panelShown = false

    /// Where the viewer puts the photo in a host of `size`: what the photo flight flies to.
    static func layout(in size: CGSize, media: Media?) -> (stage: CGRect, panel: CGFloat) {
        let panel: CGFloat = size.width >= 1100 ? 400 : 340
        let maxStageW = size.width - panel - 140
        let maxStageH = size.height - 64
        let aspect = media.map { max(0.5, min(1.91, $0.aspect)) } ?? 1
        let stageH = max(1, min(maxStageH, maxStageW / aspect))
        let stageW = stageH * aspect
        let x = (size.width - stageW - panel) / 2
        let y = (size.height - stageH) / 2
        return (CGRect(x: x, y: y, width: stageW, height: stageH), panel)
    }

    static func stageRect(in size: CGSize, media: Media?) -> CGRect { layout(in: size, media: media).stage }

    /// Closes with the photo flying back into its tile.
    private func dismiss(in size: CGSize) {
        if let flight, let media = model.media {
            flight.close(media, from: Self.stageRect(in: size, media: media))
        }
        close()
    }

    /// This viewer holds the open post (a profile opened from it shrinks it into the corner).
    private func register(_ stage: CGRect) {
        if onScreen {
            app.presentedPost = AppModel.PresentedPost(model: model, frame: stage, close: close)
        } else if app.presentedPost?.model === model {
            // A viewer on a hidden or covered page isn't the open one.
            app.presentedPost = nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            let media = model.media
            let layout = Self.layout(in: geo.size, media: media)
            let stage = layout.stage
            ZStack {
                Color.black.opacity(0.82).onTapGesture { dismiss(in: geo.size) }
                    .onAppear { register(stage) }
                    .onChange(of: stage) { register(stage) }
                    .onChange(of: model.pk) { register(stage) }
                    .onChange(of: onScreen) { register(stage) }
                    .onDisappear { if app.presentedPost?.model === model { app.presentedPost = nil } }
                HStack(spacing: 0) {
                    if let media {
                        MediaStage(media: media, cornerRadius: 0, initialImage: flight?.handoff(for: media.pk))
                            .frame(width: stage.width, height: stage.height)
                            .contextMenu { PostMenu(media: media) }
                            .overlay(alignment: .bottomLeading) {
                                RepostBubbles(media: media).padding(.leading, media.shownItem.userTags == nil ? 0 : 42)
                            }
                    }
                    MediaDetailsColumn(model: model)
                        .frame(width: layout.panel, height: stage.height)
                        .background(Theme.background)
                        .opacity(panelShown ? 1 : 0)
                        .offset(x: panelShown || Motion.reduced ? 0 : -12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(panelShown ? 0.35 : 0), radius: 30)
                HStack {
                    arrow("chevron.left", enabled: canPrevious) { step(-1) }
                    Spacer()
                    arrow("chevron.right", enabled: canNext) { step(1) }
                }
                .padding(.horizontal, 20)
                .opacity(panelShown ? 1 : 0)
                VStack {
                    HStack {
                        Spacer()
                        Button { dismiss(in: geo.size) } label: {
                            Image(systemName: "xmark").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.pressable)
                        .keyboardShortcut(.cancelAction)
                    }
                    Spacer()
                }
                .padding(12)
            }
        }
        .id(model.pk)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            withAnimation(.easeOut(duration: 0.22)) { panelShown = true }
        }
        .onKeyPress(.leftArrow) { if canPrevious { step(-1) }; return .handled }
        .onKeyPress(.rightArrow) { if canNext { step(1) }; return .handled }
        .task {
            await model.start()
            await model.refreshIfStale()
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(Circle().fill(.white.opacity(0.85)))
        }
        .buttonStyle(.pressable)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
    }
}

// MARK: - Stories column

/// Stories as a list down the left of Home: unseen first, with how long ago each was posted.
/// The stories as a strip of avatars beside the feed (unseen first). Resting on one shows who
/// it is and how long ago they posted, in a label reaching out over the feed.
private struct StoriesColumn: View {
    let reels: [StoryReel]
    let me: User?
    let add: () -> Void
    let open: (Int) -> Void
    /// The avatar under the pointer (-1: your own) and where each one is.
    @State private var hovered: Int?
    @State private var frames: [Int: CGRect] = [:]

    private var mine: Int? { me.flatMap { me in reels.firstIndex { $0.user.id == me.id } } }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if let me {
                    let reel = mine.map { reels[$0] }
                    YourStoryAvatar(user: me, reel: reel, size: 44, add: add)
                        .contentShape(Rectangle())
                        .onTapGesture { if let mine { open(mine) } else { add() } }
                        .contextMenu { Button("Add to Your Story", action: add) }
                        .modifier(Tracked(index: -1, hovered: $hovered, frames: $frames))
                }
                ForEach(order, id: \.self) { i in
                    StoryRing(seen: reels[i].seen, lineWidth: 2) { Avatar(url: reels[i].user.avatar, size: 44) }
                        .contentShape(Rectangle())
                        .onTapGesture { open(i) }
                        .modifier(Tracked(index: i, hovered: $hovered, frames: $frames))
                }
            }
            .padding(.vertical, 16)
        }
        .scrollIndicators(.never)
        .coordinateSpace(.named("storiesColumn"))
        .overlay(alignment: .topLeading) {
            if let hovered, let frame = frames[hovered] {
                label(hovered)
                    .fixedSize()
                    .offset(x: frame.maxX + 10, y: frame.midY - 19)
                    .transition(.opacity.combined(with: .offset(x: -4)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// "username · 3h", or for your own "Your story" / "Add to your story".
    private func label(_ i: Int) -> some View {
        let reel = i >= 0 ? reels[i] : mine.map { reels[$0] }
        let name = i >= 0 ? reels[i].user.username : "Your story"
        let age = reel?.latest?.shortAge ?? (i < 0 ? "Add to your story" : nil)
        return HStack(spacing: 6) {
            Text(name).font(.system(size: 12.5, weight: .semibold))
            if let age { Text(age).font(.system(size: 12)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(Capsule().fill(Theme.background))
        .overlay(Capsule().strokeBorder(Theme.panelStroke))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .padding(.vertical, 4)
    }

    /// Indices with unseen reels first, keeping the tray's own order within each group (your
    /// own is shown first on its own).
    private var order: [Int] {
        let others = reels.indices.filter { $0 != mine }
        return others.filter { !reels[$0].seen } + others.filter { reels[$0].seen }
    }
}

/// Reports an avatar's place in the column and whether the pointer is on it.
private struct Tracked: ViewModifier {
    let index: Int
    @Binding var hovered: Int?
    @Binding var frames: [Int: CGRect]

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("storiesColumn")) } action: { frames[index] = $0 }
            .onHover { inside in
                if inside { hovered = index } else if hovered == index { hovered = nil }
            }
    }
}

/// Your avatar, ringed when you have a story, with the blue "+" badge that adds to it.
struct YourStoryAvatar: View {
    let user: User
    let reel: StoryReel?
    let size: CGFloat
    let add: () -> Void

    var body: some View {
        Group {
            if let reel {
                StoryRing(seen: reel.seen, lineWidth: size > 50 ? 2.5 : 2) { Avatar(url: user.avatar, size: size) }
            } else {
                Avatar(url: user.avatar, size: size).padding(size > 50 ? 4.5 : 4)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button(action: add) {
                Image(systemName: "plus").font(.system(size: size * 0.2, weight: .heavy)).foregroundStyle(.white)
                    .frame(width: size * 0.38, height: size * 0.38)
                    .background(Circle().fill(Theme.link))
                    .overlay(Circle().strokeBorder(Theme.background, lineWidth: 2))
                    .contentShape(Circle())
            }
            .buttonStyle(.pressable)
            .help("Add to your story")
        }
    }
}

// MARK: - Stories tray

struct StoryTray: View {
    let reels: [StoryReel]
    var me: User?
    var add: () -> Void = {}
    let open: (Int) -> Void

    private var mine: Int? { me.flatMap { me in reels.firstIndex { $0.user.id == me.id } } }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 14) {
                if let me {
                    let reel = mine.map { reels[$0] }
                    Button { if let mine { open(mine) } else { add() } } label: {
                        VStack(spacing: 6) {
                            YourStoryAvatar(user: me, reel: reel, size: 58, add: add)
                            Text("Your story").font(.system(size: 11)).lineLimit(1).frame(width: 70)
                        }
                    }
                    .buttonStyle(.pressable)
                    .contextMenu { Button("Add to Your Story", action: add) }
                }
                ForEach(Array(reels.enumerated()), id: \.element.id) { index, reel in
                    if index != mine {
                    Button { open(index) } label: {
                        VStack(spacing: 6) {
                            StoryRing(seen: reel.seen) {
                                Avatar(url: reel.user.avatar, size: 58)
                            }
                            Text(reel.user.username)
                                .font(.system(size: 11))
                                .foregroundStyle(reel.seen ? .secondary : .primary)
                                .lineLimit(1)
                                .frame(width: 70)
                        }
                    }
                    .buttonStyle(.pressable)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.never)
        .frame(height: 96)
    }
}

/// The gradient ring around an avatar with unseen stories (grey once seen).
struct StoryRing<Content: View>: View {
    var seen: Bool
    var lineWidth: CGFloat = 2.5
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(lineWidth + 2)
            .overlay {
                Circle().strokeBorder(seen ? AnyShapeStyle(Color.primary.opacity(0.18)) : AnyShapeStyle(Theme.storyGradient),
                                      lineWidth: seen ? 1.2 : lineWidth)
            }
    }
}

extension Theme {
    static let storyGradient = AngularGradient(
        colors: [Color(red: 0.98, green: 0.69, blue: 0.21), Color(red: 0.96, green: 0.27, blue: 0.36),
                 Color(red: 0.78, green: 0.16, blue: 0.62), Color(red: 0.98, green: 0.69, blue: 0.21)],
        center: .center)
}

/// "3 new posts": newer posts are waiting above; clicking puts them on top and scrolls up.
private struct NewPostsPill: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                Text(count == 1 ? "1 new post" : "\(count) new posts")
            }
            .font(.system(size: 13, weight: .semibold))
        }
        .buttonStyle(.prominentCompact)
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .accessibilityLabel(count == 1 ? "Show 1 new post" : "Show \(count) new posts")
    }
}
