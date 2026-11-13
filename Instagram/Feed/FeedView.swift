import SwiftUI

struct FeedView: View {
    @Environment(AppModel.self) private var app
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
        flight.open(posts[i], to: PostLightbox.stageRect(in: flight.hostSize, media: posts[i])) {}
        model.open(at: i)
    }
    /// The stories column folded to a strip of avatars (remembered).
    @AppStorage("storiesCollapsed") private var storiesCollapsed = false

    var body: some View {
        GeometryReader { geo in
            // Wide windows: stories as a column on the left, posts in as many columns as fit.
            let storiesColumn = geo.size.width >= 1000 && (!model.tray.isEmpty || app.me != nil)
            let storiesWidth: CGFloat = storiesCollapsed ? 76 : 250
            let gridWidth = geo.size.width - (storiesColumn ? storiesWidth : 0) - 48
            let columns = max(1, min(4, Int((gridWidth + 16) / (300 + 16))))
            let columnWidth = min(420, (gridWidth - CGFloat(columns - 1) * 16) / CGFloat(columns))
            HStack(spacing: 0) {
                if storiesColumn {
                    StoriesColumn(reels: model.tray, me: app.me, collapsed: $storiesCollapsed,
                                  add: { app.openStoryEditor() }) { app.openStories(model.tray, at: $0) }
                        .frame(width: storiesWidth)
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                }
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
                }
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y > 60 } action: { model.scrolledAway = $1 }
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
                }
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel))
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
                            .overlay(alignment: .bottomLeading) { RepostBubbles(media: media) }
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
        .task { await model.start() }
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
private struct StoriesColumn: View {
    let reels: [StoryReel]
    let me: User?
    @Binding var collapsed: Bool
    let add: () -> Void
    let open: (Int) -> Void

    private var mine: Int? { me.flatMap { me in reels.firstIndex { $0.user.id == me.id } } }

    var body: some View {
        VStack(alignment: collapsed ? .center : .leading, spacing: 0) {
            HStack {
                if !collapsed {
                    Text("Stories").font(.system(size: 15, weight: .bold))
                    Spacer()
                    let unseen = reels.filter { !$0.seen }.count
                    if unseen > 0 {
                        Text("\(unseen) new").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                ChromeButton(collapsed ? "Show stories" : "Hide stories",
                             symbol: collapsed ? "sidebar.left" : "chevron.left.2") {
                    withAnimation(.smooth(duration: 0.25)) { collapsed.toggle() }
                }
            }
            .padding(.horizontal, collapsed ? 0 : 16)
            .frame(maxWidth: .infinity, alignment: collapsed ? .center : .leading)
            .frame(height: 52)
            ScrollView {
                LazyVStack(spacing: collapsed ? 10 : 2) {
                    if let me {
                        let reel = mine.map { reels[$0] }
                        Group {
                            if collapsed {
                                YourStoryAvatar(user: me, reel: reel, size: 44, add: add)
                                    .help(reel == nil ? "Add to your story" : "Your story")
                            } else {
                                YourStoryRow(user: me, reel: reel, add: add)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if let mine { open(mine) } else { add() } }
                        .contextMenu { Button("Add to Your Story", action: add) }
                    }
                    ForEach(order, id: \.self) { i in
                        Group {
                            if collapsed {
                                StoryRing(seen: reels[i].seen, lineWidth: 2) { Avatar(url: reels[i].user.avatar, size: 44) }
                                    .help(reels[i].user.username)
                            } else {
                                StoryRow(reel: reels[i])
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { open(i) }
                    }
                }
                .padding(.horizontal, collapsed ? 0 : 8)
                .padding(.vertical, collapsed ? 4 : 0)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
    }

    /// Indices with unseen reels first, keeping the tray's own order within each group (your
    /// own is shown on its own row first).
    private var order: [Int] {
        let others = reels.indices.filter { $0 != mine }
        return others.filter { !reels[$0].seen } + others.filter { reels[$0].seen }
    }
}

private struct StoryRow: View {
    let reel: StoryReel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            StoryRing(seen: reel.seen, lineWidth: 2) { Avatar(url: reel.user.avatar, size: 38) }
            VStack(alignment: .leading, spacing: 1) {
                Text(reel.user.username)
                    .font(.system(size: 13, weight: reel.seen ? .regular : .semibold))
                    .foregroundStyle(reel.seen ? .secondary : .primary)
                    .lineLimit(1)
                if let t = reel.latest {
                    Text(t.shortAge).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// Your own row: "Your story" with a "+" to add to it (Instagram's first tray entry).
private struct YourStoryRow: View {
    let user: User
    let reel: StoryReel?
    let add: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            YourStoryAvatar(user: user, reel: reel, size: 38, add: add)
            VStack(alignment: .leading, spacing: 1) {
                Text("Your story").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(reel == nil ? "Add to your story" : reel?.latest?.shortAge ?? "Click to view")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
