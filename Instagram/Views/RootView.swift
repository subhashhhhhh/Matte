import SwiftUI
import UniformTypeIdentifiers

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
                    VStack(spacing: 0) {
                        TopBar().zIndex(1)
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            if app.showSwitcher, app.authState == .signedIn {
                QuickSwitcher()
                    .transition(.opacity)
                    .zIndex(25)
            }
            if let media = app.sharing {
                ShareSheet(media: media)
                    .id(media.pk)
                    .transition(.opacity)
                    .zIndex(20)
            }
            if let create = app.creating {
                CreateSheet(model: create)
                    .transition(.opacity)
                    .zIndex(21)
            }
            if let media = app.editingCaption {
                CaptionEditSheet(media: media)
                    .id(media.pk)
                    .transition(.opacity)
                    .zIndex(22)
            }
            if let media = app.confirmingDelete {
                DeletePostDialog(media: media)
                    .id(media.pk)
                    .transition(.opacity)
                    .zIndex(23)
            }
            if let stories = app.stories {
                StoryViewer(model: stories)
                    .transition(.opacity)
                    .zIndex(10)
            }
            if app.showCreateMenu, app.authState == .signedIn {
                CreateMenu()
                    .transition(.opacity)
                    .zIndex(24)
            }
            if let urls = app.droppedFiles {
                DropChooser(urls: urls)
                    .transition(.opacity)
                    .zIndex(26)
            }
            if let editor = app.storyEditor {
                StoryEditorView(model: editor)
                    .transition(.opacity.combined(with: .scale(scale: Motion.reduced ? 1 : 0.985)))
                    .zIndex(30)
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
        .animation(Motion.pop, value: app.toast)
        .animation(.easeOut(duration: 0.2), value: app.stories == nil)
        .animation(.easeOut(duration: 0.16), value: app.sharing == nil)
        .animation(.easeOut(duration: 0.16), value: app.creating == nil)
        .animation(.easeOut(duration: 0.2), value: app.storyEditor == nil)
        .animation(.easeOut(duration: 0.12), value: app.showCreateMenu)
        .animation(.easeOut(duration: 0.14), value: app.droppedFiles == nil)
        .animation(.easeOut(duration: 0.14), value: app.editingCaption == nil)
        .animation(.easeOut(duration: 0.14), value: app.confirmingDelete == nil)
        // Photos dropped anywhere on the window open the create sheet with them; a video asks
        // reel or story (places that take files themselves, like a chat's composer, get them first).
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard app.authState == .signedIn, app.creating == nil, app.storyEditor == nil else { return false }
            Task { app.dropped(await CreateSheet.urls(from: providers)) }
            return true
        }
        .animation(.easeOut(duration: 0.14), value: app.showSwitcher)
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
                FeedView(model: feed).pageVisibility(app.destination == .home)
            }
            if let explore = app.explore, app.visited.contains(.explore) {
                ExploreView(model: explore).pageVisibility(app.destination == .explore)
            }
            if let reels = app.reels, app.destination == .reels, app.profiles.isEmpty {
                ReelsView(model: reels)
                    .transition(.opacity.combined(with: .offset(y: Motion.reduced ? 0 : 10)))
            }
            if let inbox = app.inbox, app.visited.contains(.messages) {
                MessagesView(model: inbox).pageVisibility(app.destination == .messages)
            }
            // A profile opened from anywhere covers the page until you go back.
            if let page = app.profiles.last {
                StackPageView(page: page)
                    .id(page.id)
                    .background(Theme.background)
                    .transition(.push)
            }
        }
        .overlay(alignment: .trailing) {
            if let activity = app.activity, activity.isOpen {
                ActivityPanel(model: activity)
                    .transition(.move(edge: .trailing))
            }
        }
        .overlay {
            if let activity = app.activity, let opened = activity.opened {
                PostLightbox(model: opened, canPrevious: false, canNext: false, step: { _ in },
                             close: { activity.opened = nil })
                    .transition(.opacity)
            }
        }
        .animation(Motion.page, value: app.activity?.isOpen)
        .animation(Motion.page, value: app.profiles.count)
        .animation(Motion.page, value: app.destination)
    }
}
