import SwiftUI

struct FeedView: View {
    @Environment(AppModel.self) private var app
    let model: FeedModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if !model.tray.isEmpty {
                    StoryTray(reels: model.tray) { index in app.openStories(model.tray, at: index) }
                        .padding(.vertical, 14)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                ForEach(model.posts) { post in
                    PostCard(post: post, isPlaying: model.playing == post.pk) { playing in
                        if playing { model.playing = post.pk } else if model.playing == post.pk { model.playing = nil }
                    }
                    .padding(.vertical, 18)
                    .onAppear {
                        if post.pk == model.posts.dropLast(3).last?.pk || post.pk == model.posts.last?.pk {
                            Task { await model.loadMore() }
                        }
                    }
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                if model.isLoading || model.isLoadingMore {
                    Spinner().padding(30)
                }
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .overlay {
            if model.posts.isEmpty, model.loadFailed {
                EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't load your feed", actionTitle: "Try Again") {
                    Task { await model.refresh() }
                }
            } else if model.posts.isEmpty, model.isLoading {
                Spinner(size: 22)
            }
        }
        .task { await model.loadIfNeeded() }
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
