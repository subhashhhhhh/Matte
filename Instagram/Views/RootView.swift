import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var app
    /// Where the pages sit in the window (below the top bar, beside the sidebar).
    @State private var pageArea: CGRect = .zero

    var body: some View {
        @Bindable var app = app
        ZStack {
            switch app.authState {
            case .signedOut:
                WelcomeView()
            case .signedIn:
                HStack(spacing: 0) {
                    Sidebar()
                    VStack(spacing: 0) {
                        TopBar().zIndex(1)
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    // A new account's pages are new views: each runs its first load again.
                    .id(app.generation)
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
            // A post opened over everything (a story's post sticker, the mini player going back):
            // above stories, below the sheets it can open (Send to…, edit, delete), in the page
            // area like every other post viewer (so the mini player grows exactly into it).
            if let post = app.openedPost {
                PostLightbox(model: post, canPrevious: false, canNext: false, step: { _ in },
                             close: { app.openedPost = nil; app.openedPostFromMini = false })
                    .environment(\.onScreen, app.storyEditor == nil && app.creating == nil)
                    .frame(width: pageArea.width, height: pageArea.height)
                    .position(x: pageArea.midX, y: pageArea.midY)
                    .transition(app.openedPostFromMini ? .asymmetric(insertion: .identity, removal: .opacity) : .opacity)
                    .zIndex(15)
            }
            if let list = app.peopleList {
                FollowListPanel(model: list) { app.peopleList = nil }
                    .id(list.id)
                    .transition(.opacity)
                    .zIndex(18)
            }
            if app.showCreateMenu, app.authState == .signedIn {
                CreateMenu()
                    .transition(.opacity)
                    .zIndex(24)
            }
            if app.showSettings {
                SettingsView()
                    .transition(.opacity)
                    .zIndex(27)
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
        .animation(.easeOut(duration: 0.16), value: app.openedPost == nil)
        .overlay(alignment: .bottomTrailing) {
            if !app.uploads.isEmpty, app.storyEditor == nil { UploadsCorner() }
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
        .animation(.easeOut(duration: 0.16), value: app.peopleList?.id)
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
        .animation(.easeOut(duration: 0.14), value: app.showSettings)
        .background(Theme.background)
        .coordinateSpace(.named("root"))
        .ignoresSafeArea()
        // As in Velvet and Twitter: an empty, invisible system toolbar (unified style) only so
        // macOS puts the window buttons lower and further in, inside the sidebar panel. Matte
        // draws its own top bar under it.
        .toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { Color.clear.frame(width: 1, height: 1) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { Color.clear.frame(width: 1, height: 1) }
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // In fullscreen the toolbar (and its window buttons) comes down with the menu bar only
        // when the pointer is at the top of the screen.
        .windowToolbarFullScreenVisibility(.onHover)
        // Appearance (Settings › General): light, dark or the Mac's.
        .onAppear { Preferences.shared.applyAppearance() }
        .sheet(isPresented: $app.showSignIn) {
            SignInView(onComplete: { app.completeSignIn($0) }, onCancel: { app.showSignIn = false })
        }
    }

    /// Something covers every page: a story, the story editor, an opened post, the create sheet.
    private var overlayCovers: Bool {
        app.stories != nil || app.storyEditor != nil || app.openedPost != nil || app.creating != nil || app.activity?.opened != nil
    }

    /// Whether the page for `d` is the one you're looking at (sound plays only there).
    private func onScreen(_ d: Destination) -> Bool {
        app.destination == d && app.profiles.isEmpty && !overlayCovers
    }

    @ViewBuilder
    private var content: some View {
        // Pages stay alive while hidden, so each keeps its scroll position and state;
        // only the visible one does any work or plays anything (`onScreen`).
        ZStack {
            if let feed = app.feed, app.visited.contains(.home) {
                FeedView(model: feed).pageVisibility(app.destination == .home)
                    .environment(\.onScreen, onScreen(.home))
            }
            if let explore = app.explore, app.visited.contains(.explore) {
                ExploreView(model: explore).pageVisibility(app.destination == .explore)
                    .environment(\.onScreen, onScreen(.explore))
            }
            if let reels = app.reels, app.destination == .reels, app.profiles.isEmpty {
                ReelsView(model: reels)
                    .environment(\.onScreen, !overlayCovers)
                    .transition(.opacity.combined(with: .offset(y: Motion.reduced ? 0 : 10)))
            }
            if let inbox = app.inbox, app.visited.contains(.messages) {
                MessagesView(model: inbox).pageVisibility(app.destination == .messages)
                    .environment(\.onScreen, onScreen(.messages))
            }
            if let planner = app.planner, app.managerMode, app.visited.contains(.planner) {
                PlannerView(model: planner).pageVisibility(app.destination == .planner)
                    .environment(\.onScreen, onScreen(.planner))
            }
            if let replies = app.replies, app.managerMode, app.visited.contains(.replies) {
                RepliesView(model: replies).pageVisibility(app.destination == .replies)
                    .environment(\.onScreen, onScreen(.replies))
            }
            // A profile opened from anywhere covers the page until you go back.
            if let page = app.profiles.last {
                StackPageView(page: page)
                    .id(page.id)
                    .environment(\.onScreen, !overlayCovers)
                    .background(Theme.background)
                    .transition(.push)
            }
        }
        .coordinateSpace(.named("pageArea"))
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("root")) } action: { pageArea = $0 }
        // The post or reel you left for a profile, small in the corner (under any opened post).
        .overlay {
            if let mini = app.miniPost {
                MiniPlayer(mini: mini)
                    .id(mini.id)
                    .environment(\.onScreen, !overlayCovers && app.presentedPost == nil)
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
                    .environment(\.onScreen, app.stories == nil && app.storyEditor == nil && app.openedPost == nil && app.creating == nil)
                    .transition(.opacity)
            }
        }
        .animation(Motion.page, value: app.activity?.isOpen)
        .animation(Motion.page, value: app.profiles.count)
        .animation(Motion.page, value: app.destination)
    }
}
