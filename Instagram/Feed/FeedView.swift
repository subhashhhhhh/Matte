import SwiftUI

struct FeedView: View {
    @Environment(AppModel.self) private var app
    let model: FeedModel
    /// The stories column folded to a strip of avatars (remembered).
    @AppStorage("storiesCollapsed") private var storiesCollapsed = false

    var body: some View {
        GeometryReader { geo in
            // Wide windows: stories as a column on the left, posts in as many columns as fit.
            let storiesColumn = geo.size.width >= 1000 && !model.tray.isEmpty
            let storiesWidth: CGFloat = storiesCollapsed ? 76 : 250
            let gridWidth = geo.size.width - (storiesColumn ? storiesWidth : 0) - 48
            let columns = max(1, min(4, Int((gridWidth + 16) / (300 + 16))))
            let columnWidth = min(420, (gridWidth - CGFloat(columns - 1) * 16) / CGFloat(columns))
            HStack(spacing: 0) {
                if storiesColumn {
                    StoriesColumn(reels: model.tray, collapsed: $storiesCollapsed) { app.openStories(model.tray, at: $0) }
                        .frame(width: storiesWidth)
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                }
                ScrollView {
                    VStack(spacing: 16) {
                        if !storiesColumn, !model.tray.isEmpty {
                            StoryTray(reels: model.tray) { app.openStories(model.tray, at: $0) }
                        }
                        FeedControls(model: model)
                        Masonry(model: model, columns: columns, columnWidth: columnWidth)
                        if model.isLoadingMore { Spinner().padding(20) }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.never)
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
            if let opened = model.opened {
                PostLightbox(model: opened,
                             canPrevious: (model.openedIndex ?? 0) > 0,
                             canNext: (model.openedIndex ?? 0) < model.visible.count - 1,
                             step: { model.step($0) }, close: { withAnimation(Motion.hero) { model.closeOpened() } })
                    .transition(.opacity)
            }
        }
        .environment(\.heroOpened, model.opened?.pk)
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
                                 open: { withAnimation(Motion.hero) { model.open(at: i) } })
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
    @Environment(\.heroNamespace) private var heroNS
    let model: MediaDetailModel
    let canPrevious: Bool
    let canNext: Bool
    let step: (Int) -> Void
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let panel: CGFloat = geo.size.width >= 1100 ? 400 : 340
            let maxStageW = geo.size.width - panel - 140
            let maxStageH = geo.size.height - 64
            let media = model.media
            let aspect = media.map { max(0.5, min(1.91, $0.aspect)) } ?? 1
            let stageH = min(maxStageH, maxStageW / aspect)
            ZStack {
                Color.black.opacity(0.82).onTapGesture { close() }
                HStack(spacing: 0) {
                    if let media {
                        MediaStage(media: media, cornerRadius: 0)
                            .frame(width: stageH * aspect, height: stageH)
                            .hero(model.pk, in: heroNS)
                    }
                    MediaDetailsColumn(model: model)
                        .frame(width: panel, height: stageH)
                        .background(Theme.background)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.35), radius: 30)
                HStack {
                    arrow("chevron.left", enabled: canPrevious) { step(-1) }
                    Spacer()
                    arrow("chevron.right", enabled: canNext) { step(1) }
                }
                .padding(.horizontal, 20)
                VStack {
                    HStack {
                        Spacer()
                        Button { close() } label: {
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
        .onAppear { focused = true }
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
    @Binding var collapsed: Bool
    let open: (Int) -> Void

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

    /// Indices with unseen reels first, keeping the tray's own order within each group.
    private var order: [Int] {
        reels.indices.filter { !reels[$0].seen } + reels.indices.filter { reels[$0].seen }
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

// MARK: - Stories tray

struct StoryTray: View {
    let reels: [StoryReel]
    let open: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 14) {
                ForEach(Array(reels.enumerated()), id: \.element.id) { index, reel in
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
