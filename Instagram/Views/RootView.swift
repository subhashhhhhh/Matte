import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        ZStack {
            switch app.authState {
            case .signedOut:
                EmptyState(symbol: "camera", title: "Instagram",
                           message: "Sign in on Instagram's own page. The session stays on this Mac.",
                           actionTitle: "Sign In") { app.showSignIn = true }
            case .signedIn:
                HStack(spacing: 0) {
                    Sidebar()
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let media = app.sharing {
                ShareSheet(media: media)
                    .id(media.pk)
                    .transition(.opacity)
                    .zIndex(20)
            }
            if let stories = app.stories {
                StoryViewer(model: stories)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                Text(toast)
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(.regularMaterial))
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: app.toast)
        .animation(.easeOut(duration: 0.18), value: app.stories == nil)
        .animation(.easeOut(duration: 0.15), value: app.sharing == nil)
        .background(Theme.background)
        .ignoresSafeArea()
        .sheet(isPresented: $app.showSignIn) {
            SignInView(onComplete: { app.completeSignIn($0) }, onCancel: { app.showSignIn = false })
        }
    }

    @ViewBuilder
    private var content: some View {
        // Pages stay alive while hidden, so each keeps its scroll position and state;
        // only the visible one does any work (Reels pauses when hidden).
        ZStack {
            if let feed = app.feed, app.visited.contains(.home) {
                FeedView(model: feed).opacity(app.destination == .home ? 1 : 0)
                    .allowsHitTesting(app.destination == .home)
            }
            if let reels = app.reels, app.destination == .reels {
                ReelsView(model: reels)
            }
            if let inbox = app.inbox, app.visited.contains(.messages) {
                MessagesView(model: inbox).opacity(app.destination == .messages ? 1 : 0)
                    .allowsHitTesting(app.destination == .messages)
            }
        }
        .padding(.top, 28)
    }
}
