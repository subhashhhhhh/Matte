import SwiftUI
import UniformTypeIdentifiers

struct MessagesView: View {
    @Environment(AppModel.self) private var app
    let model: InboxModel
    /// The shared-items column, when the window is wide enough for it.
    @AppStorage("showSharedPane") private var showPane = true
    @State private var viewer: MediaDetailModel?
    @State private var viewerItemId: String?
    @State private var composing = false
    @State private var newMessageQuery = ""
    /// The window has room for the shared column.
    @State private var paneFitsNow = false
    /// The shared column was opened just to show an item (it folds away again when it closes).
    @State private var paneOpenedForViewer = false

    var body: some View {
        GeometryReader { geo in
            let paneFits = geo.size.width >= 1080
            let paneWidth = min(520, max(340, geo.size.width * 0.3))
            let listWidth: CGFloat = geo.size.width >= 1300 ? 330 : 290
            let _ = syncPaneFits(paneFits)
            HStack(spacing: 0) {
                ThreadList(model: model, composing: $composing)
                    .frame(width: listWidth)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                conversationColumn(paneFits: paneFits)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if paneFits, showPane {
                    Rectangle().fill(Theme.hairline).frame(width: 1)
                    SharedPane(conversation: model.conversation, items: items, viewer: viewer, viewerItemId: viewerItemId,
                               open: open, close: closeViewer)
                        .frame(width: paneWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // Narrow window: an opened item covers the conversation instead.
            .overlay(alignment: .trailing) {
                if !(paneFits && showPane), viewer != nil {
                    SharedPane(conversation: model.conversation, items: items, viewer: viewer, viewerItemId: viewerItemId,
                               open: open, close: closeViewer)
                        .frame(width: min(geo.size.width - listWidth, 520))
                        .background(Theme.background)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 1) }
                        .transition(.move(edge: .trailing))
                }
            }
            .environment(\.openInViewer, openRequest)
            .environment(\.sharedPaneToggle, paneFits ? {
                // Your choice now: it stays as you leave it.
                paneOpenedForViewer = false
                withAnimation(.smooth(duration: 0.25)) { showPane.toggle() }
            } : nil)
            .environment(\.sharedPaneShown, paneFits && showPane)
        }
        .animation(.smooth(duration: 0.25), value: viewer?.id)
        .overlay {
            if let c = model.conversation, let m = c.forwarding {
                ForwardSheet(conversation: c, message: m)
            }
        }
        .overlay {
            if composing {
                NewMessageSheet(close: { composing = false }, initialQuery: newMessageQuery) { user in
                    composing = false
                    model.startChat(with: user)
                }
            }
        }
        .onChange(of: model.selectedId) { closeViewer() }
        .task {
            await model.loadIfNeeded()
            #if DEBUG
            // `-IGNewMessage <query>`: open "New message" searching for <query> (screenshots).
            if let q = UserDefaults.standard.string(forKey: "IGNewMessage") { newMessageQuery = q; composing = true }
            // `-IGNewChatWith <query>`: open a new (unsent) chat with the first account found.
            if let q = UserDefaults.standard.string(forKey: "IGNewChatWith"),
               let user = try? await app.client?.search(q, sessionId: UUID().uuidString.lowercased()).users.first {
                model.startChat(with: user)
            }
            // `-IGOpenThread N`: open the Nth chat at launch, only if it's already read (opening
            // an unread chat would mark it read).
            let n = UserDefaults.standard.integer(forKey: "IGOpenThread")
            if UserDefaults.standard.object(forKey: "IGOpenThread") != nil, model.threads.indices.contains(n),
               !model.threads[n].isUnread {
                try? await Task.sleep(for: .seconds(3))
                model.selectedId = model.threads[n].id
                // `-IGStageFile <path>`: put a photo/video in that chat's composer (nothing is sent).
                if let path = UserDefaults.standard.string(forKey: "IGStageFile") {
                    try? await Task.sleep(for: .seconds(1))
                    model.conversation?.stage(files: [URL(fileURLWithPath: path)])
                }
                // `-IGOpenShared N`: open the Nth shared item (newest first) in the side pane.
                if UserDefaults.standard.object(forKey: "IGOpenShared") != nil {
                    for _ in 0..<20 where items.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                    let k = UserDefaults.standard.integer(forKey: "IGOpenShared")
                    if items.indices.contains(k) { open(items[k]) }
                }
                // `-IGForwardLast YES`: open "Forward to…" for the newest forwardable message (nothing is sent).
                if UserDefaults.standard.bool(forKey: "IGForwardLast"), let c = model.conversation {
                    try? await Task.sleep(for: .seconds(2))
                    c.forwarding = c.messages.last(where: c.canForward)
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private func conversationColumn(paneFits: Bool) -> some View {
        // Switching chats: the new one slides in a little from the right as the old one fades.
        ZStack {
            if let user = model.newChatUser {
                NewChatView(model: model, user: user)
                    .id("new-\(user.id)")
                    .transition(Self.chatTransition)
            } else if let conversation = model.conversation {
                ConversationView(model: conversation)
                    .id(conversation.thread.id)
                    .transition(Self.chatTransition)
            } else {
                EmptyState(symbol: "paperplane", title: "Your messages",
                           message: "Pick a conversation on the left.")
                    .transition(.opacity)
            }
        }
        .animation(Motion.page, value: model.selectedId)
        .animation(Motion.page, value: model.newChatUser?.id)
    }

    private static var chatTransition: AnyTransition {
        Motion.reduced ? .opacity : .asymmetric(insertion: .offset(x: 28).combined(with: .opacity), removal: .opacity)
    }

    private var items: [SharedItem] { SharedItem.items(in: model.conversation?.messages ?? []) }

    private func open(_ item: SharedItem) {
        showPaneForViewer()
        viewerItemId = item.id
        viewer = makeViewer(item.request)
    }

    private func openRequest(_ request: ViewerRequest) {
        if let item = items.first(where: { $0.request == request }) { open(item); return }
        showPaneForViewer()
        viewerItemId = nil
        viewer = makeViewer(request)
    }

    /// With room for it, an opened item shows in the shared column beside the chat (opening the
    /// column if it was folded away), never over the chat.
    private func showPaneForViewer() {
        guard paneFitsNow, !showPane else { return }
        paneOpenedForViewer = true
        withAnimation(.smooth(duration: 0.25)) { showPane = true }
    }

    private func syncPaneFits(_ fits: Bool) {
        guard fits != paneFitsNow else { return }
        DispatchQueue.main.async { paneFitsNow = fits }
    }

    private func makeViewer(_ request: ViewerRequest) -> MediaDetailModel? {
        switch request {
        case .share(let share):
            guard let pk = share.mediaPk else {
                if let url = share.targetURL { NSWorkspace.shared.open(url) }
                return nil
            }
            return MediaDetailModel.cached(pk: pk, client: app.client, fallbackURL: share.targetURL)
        case .attachment(let a):
            return MediaDetailModel(attachment: a)
        }
    }

    private func closeViewer() {
        viewer = nil
        viewerItemId = nil
        if paneOpenedForViewer {
            paneOpenedForViewer = false
            withAnimation(.smooth(duration: 0.25)) { showPane = false }
        }
    }
}

extension EnvironmentValues {
    /// Shows or hides the Messages shared column (nil when the window is too narrow for it).
    @Entry var sharedPaneToggle: (() -> Void)? = nil
    @Entry var sharedPaneShown = false
}

// MARK: - Thread list

private struct ThreadList: View {
    @Namespace private var selection
    let model: InboxModel
    @Binding var composing: Bool
    @State private var folder = Folder.chats
    @State private var showHidden = false

    enum Folder: Hashable { case chats, requests }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Messages").font(.system(size: 20, weight: .bold))
                Spacer()
                if model.isLoading || model.loadingRequests { Spinner(size: 14) }
                ChromeButton("Refresh", symbol: "arrow.clockwise") {
                    Task { folder == .chats ? await model.refresh() : await model.loadRequests(force: true) }
                }
                ChromeButton("New Message", symbol: "square.and.pencil", shortcut: "n") { composing = true }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            SegmentedTabs(tabs: [(Folder.chats, "Chats"),
                                 (Folder.requests, model.requests.isEmpty ? "Requests" : "Requests \(model.requests.count)")],
                          selection: $folder)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 2) {
                    switch folder {
                    case .chats:
                        ForEach(model.threads) { thread in
                            row(thread)
                                .onAppear {
                                    if thread.id == model.threads.last?.id { Task { await model.loadMore() } }
                                }
                        }
                    case .requests:
                        ForEach(model.requests) { row($0) }
                        if !model.hiddenRequests.isEmpty {
                            Button { withAnimation(.smooth(duration: 0.2)) { showHidden.toggle() } } label: {
                                HStack {
                                    Text("Hidden requests").font(.system(size: 13, weight: .semibold))
                                    Text("\(model.hiddenRequests.count)").font(.system(size: 13)).foregroundStyle(.secondary)
                                    Spacer()
                                    Image(systemName: showHidden ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .frame(height: 36)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 8)
                            if showHidden { ForEach(model.hiddenRequests) { row($0) } }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)
            .overlay {
                if folder == .chats, model.threads.isEmpty, model.loadFailed {
                    EmptyState(symbol: "wifi.exclamationmark", title: "Couldn't load messages", actionTitle: "Try Again") {
                        Task { await model.refresh() }
                    }
                } else if folder == .requests, model.requests.isEmpty, model.hiddenRequests.isEmpty, !model.loadingRequests {
                    EmptyState(symbol: "tray", title: "No message requests",
                               message: "Messages from people you don't follow show up here.")
                }
            }
        }
        .task {
            #if DEBUG
            // `-IGInboxFolder requests`: open on the requests list (screenshots).
            if UserDefaults.standard.string(forKey: "IGInboxFolder") == "requests" { folder = .requests }
            #endif
            await model.loadRequests()
        }
        .onChange(of: folder) { if folder == .requests { Task { await model.loadRequests() } } }
    }

    private func row(_ thread: DMThread) -> some View {
        ThreadRow(thread: thread, selected: model.selectedId == thread.id, presence: model.presence(for: thread),
                  selection: selection)
            .onTapGesture { withAnimation(Motion.slide) { model.selectedId = thread.id } }
    }
}

private struct ThreadRow: View {
    let thread: DMThread
    let selected: Bool
    var presence: Presence?
    /// The selection highlight glides between rows.
    var selection: Namespace.ID?
    @State private var hovering = false

    /// Instagram's snippet sometimes already says "You…" ("You sent an attachment").
    private var snippet: String {
        let text = thread.snippet ?? ""
        return thread.lastSenderIsViewer && !text.hasPrefix("You") ? "You: " + text : text
    }

    var body: some View {
        HStack(spacing: 12) {
            ThreadAvatar(thread: thread, size: 50)
                .overlay(alignment: .bottomTrailing) { if presence?.isActive == true { ActiveDot(size: 14) } }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(thread.title)
                        .font(.system(size: 14, weight: thread.isUnread ? .bold : .medium))
                        .lineLimit(1)
                    if thread.users.count == 1, thread.users[0].isVerified { VerifiedBadge(size: 11) }
                }
                HStack(spacing: 4) {
                    Text(snippet)
                        .lineLimit(1)
                        .foregroundStyle(thread.isUnread ? .primary : .secondary)
                        .fontWeight(thread.isUnread ? .semibold : .regular)
                    if let t = thread.lastActivity {
                        Text("· \(t.shortAge)").foregroundStyle(.secondary).fixedSize()
                    }
                }
                .font(.system(size: 12.5))
            }
            Spacer(minLength: 0)
            if thread.isMuted { Image(systemName: "bell.slash").font(.system(size: 11)).foregroundStyle(.secondary) }
            if thread.isUnread { Circle().fill(Theme.link).frame(width: 8, height: 8) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if selected {
                let shape = RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.selected)
                if let selection { shape.matchedGeometryEffect(id: "selected-thread", in: selection) } else { shape }
            } else if hovering {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.hover)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct ThreadAvatar: View {
    let thread: DMThread
    var size: CGFloat

    var body: some View {
        if thread.isGroup, thread.users.count >= 2, thread.imageURL == nil {
            ZStack(alignment: .bottomTrailing) {
                Avatar(url: thread.users[0].avatar, size: size * 0.7)
                    .frame(width: size, height: size, alignment: .topLeading)
                Avatar(url: thread.users[1].avatar, size: size * 0.7)
                    .overlay(Circle().strokeBorder(Theme.background, lineWidth: 2))
            }
            .frame(width: size, height: size)
        } else {
            Avatar(url: thread.imageURL ?? thread.users.first?.avatar, size: size)
        }
    }
}

// MARK: - Conversation

struct ConversationView: View {
    /// A message arriving: grows out of its corner (yours from the right, theirs from the left).
    static func arrival(mine: Bool) -> AnyTransition {
        Motion.reduced ? .opacity : .asymmetric(
            insertion: .scale(scale: 0.8, anchor: mine ? .bottomTrailing : .bottomLeading).combined(with: .opacity),
            removal: .opacity)
    }

    let model: ConversationModel
    @Environment(AppModel.self) private var app
    @Environment(\.sharedPaneToggle) private var togglePane
    @Environment(\.sharedPaneShown) private var paneShown
    @State private var atBottom = true
    /// Whether the chat sticks to the newest message: on until you scroll up, back on when you
    /// scroll to the bottom. Loading content never turns it off.
    @State private var following = true
    @State private var programmaticScroll = Date.distantPast
    /// Set once the chat has opened at the newest message.
    @State private var settled = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if model.hasOlder {
                            Color.clear.frame(height: 1)
                                .onAppear {
                                    // Not while the chat is still settling at the bottom: on open, the
                                    // top is briefly on screen, and loading then would leave you mid-chat.
                                    guard settled else { return }
                                    // Keep the message you were reading in place as older ones are added above.
                                    let anchor = model.messages.first?.id
                                    Task {
                                        await model.loadOlder()
                                        if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                    }
                                }
                            if model.loadingOlder { Spinner(size: 14).padding(8) }
                        }
                        ForEach(Array(model.messages.enumerated()), id: \.element.id) { i, message in
                            if showsTime(at: i) {
                                Text(message.sentAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 10)
                            }
                            MessageRow(message: message, model: model,
                                       showAvatar: showsAvatar(at: i))
                                .id(message.id)
                                .transition(Self.arrival(mine: message.senderId == model.viewerId))
                        }
                        if let status = deliveryStatus {
                            Text(status)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .padding(.trailing, 6)
                                .padding(.top, 2)
                                .transition(.opacity)
                        }
                        if model.peerTyping { TypingRow(thread: model.thread).id("typing") }
                        Color.clear.frame(height: 8).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    // New messages pop in from their side (not the first load or older history).
                    .animation(settled ? Motion.pop : nil, value: model.messages.last?.id)
                }
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .scrollIndicators(.never)
                // Stick to the bottom: whenever the content or the view changes size (a chat opening,
                // rows being measured, a new message, the shared column opening), go back to the
                // newest message if you were at it just before. Scrolled up, your place is left alone.
                .onScrollGeometryChange(for: ChatGeometry.self) { g in
                    ChatGeometry(content: g.contentSize.height, offset: g.contentOffset.y, container: g.containerSize.height,
                                 width: g.containerSize.width)
                } action: { old, new in
                    atBottom = new.isAtBottom
                    let resized = new.content != old.content || new.container != old.container || new.width != old.width
                    if resized {
                        // Content above or below changed size (rows measured, older messages
                        // loaded, the shared column toggled): keep following if we were.
                        if following || !settled {
                            programmaticScroll = .now
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    } else if Date.now.timeIntervalSince(programmaticScroll) > 0.4 {
                        // Only the position moved, and not by us: that's you scrolling.
                        following = new.offset + new.container >= new.content - 60
                    }
                }
                // Follow new messages only when you're already at the bottom, or when it's yours.
                .onChange(of: model.messages.last?.id) { old, new in
                    guard old != new else { return }
                    let mine = model.messages.last?.senderId == model.viewerId
                    if old == nil {
                        // First load: jump (no animation), again once lazy rows have real heights,
                        // and only then allow loading older messages.
                        proxy.scrollTo("bottom", anchor: .bottom)
                        Task {
                            for delay in [80, 200, 400] {
                                try? await Task.sleep(for: .milliseconds(delay))
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                            settled = true
                        }
                        return
                    }
                    // Your own message always brings you down; others' only if you were there
                    // (the size change above already handled that case).
                    if mine {
                        following = true
                        programmaticScroll = .now
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            .overlay { if model.isLoading && model.messages.isEmpty { Spinner(size: 20) } }
            if model.thread.isRequest {
                RequestBar(model: model)
            } else {
                Composer(model: model)
            }
        }
        // Drop photos or videos anywhere on the chat to add them to the message.
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            Self.accept(providers, into: model)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.link, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.background.opacity(0.85)))
                    .overlay {
                        VStack(spacing: 8) {
                            PhotoGlyph().frame(width: 34, height: 34)
                            Text("Drop to add to your message").font(.system(size: 14, weight: .semibold))
                        }
                    }
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    @State private var dropTargeted = false

    private static func accept(_ providers: [NSItemProvider], into model: ConversationModel) -> Bool {
        var any = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                any = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, OutgoingMedia.isMediaFile(url) else { return }
                    Task { @MainActor in model.stage(files: [url]) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                any = true
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in model.stage(imageData: data) }
                }
            }
        }
        return any
    }

    private var header: some View {
        HStack(spacing: 10) {
            ThreadAvatar(thread: model.thread, size: 34)
                .overlay(alignment: .bottomTrailing) { if model.presence?.isActive == true { ActiveDot(size: 11) } }
                .opensProfile(model.thread.isGroup ? nil : model.thread.users.first)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.thread.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if let status = model.presence?.statusText {
                    Text(status).font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else if !model.thread.isGroup, let u = model.thread.users.first, u.fullName != model.thread.title {
                    Text(u.username).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let key = model.thread.threadKey, let url = URL(string: "https://www.instagram.com/direct/t/\(key)/") {
                ChromeButton("Open on Instagram", symbol: "arrow.up.right") { NSWorkspace.shared.open(url) }
            }
            if let togglePane {
                ChromeButton(paneShown ? "Hide Shared" : "Show Shared", symbol: "sidebar.right", shortcut: "s", modifiers: [.command, .shift],
                             action: togglePane)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 56)
    }

    /// "Sent" / "Seen" / "Seen by …" under your last message, when it's the newest in the chat,
    /// from each person's read position.
    private var deliveryStatus: String? {
        guard let last = model.messages.last, let me = model.viewerId, last.senderId == me,
              !last.pending, !last.failed else { return nil }
        let readers = model.thread.readUpTo.filter { $0.key != me && $0.value >= last.sentAt }.map(\.key)
        guard !readers.isEmpty else { return "Sent" }
        guard model.thread.isGroup else { return "Seen" }
        if readers.count >= model.thread.users.count { return "Seen by everyone" }
        let names = readers.compactMap { model.user(for: $0)?.username }
        return names.isEmpty ? "Seen by \(readers.count)" : "Seen by " + ListFormatter.localizedString(byJoining: names)
    }

    /// A time label before a message that comes 30+ minutes after the previous one.
    private func showsTime(at i: Int) -> Bool {
        guard i > 0 else { return true }
        return model.messages[i].sentAt.timeIntervalSince(model.messages[i - 1].sentAt) > 1800
    }

    /// The sender's avatar on the last of a run of their messages.
    private func showsAvatar(at i: Int) -> Bool {
        let m = model.messages[i]
        guard m.senderId != model.viewerId else { return false }
        guard i + 1 < model.messages.count else { return true }
        return model.messages[i + 1].senderId != m.senderId || showsTime(at: i + 1)
    }
}

/// "typing…" under the last message while the other person is typing.
private struct TypingRow: View {
    let thread: DMThread
    @State private var phase = false

    var body: some View {
        HStack(spacing: 8) {
            ThreadAvatar(thread: thread, size: 26)
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color.secondary).frame(width: 6, height: 6)
                        .opacity(phase ? 1 : 0.3)
                        .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: phase)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panel))
            Spacer()
        }
        .padding(.top, 4)
        .onAppear { phase = true }
    }
}

/// The chat scroll view's size and position, to tell "was at the newest message" before a change.
private struct ChatGeometry: Equatable {
    var content: CGFloat
    var offset: CGFloat
    var container: CGFloat
    var width: CGFloat
    var isAtBottom: Bool { offset + container >= content - 24 }
}

/// The green dot on someone who's active now.
struct ActiveDot: View {
    var size: CGFloat = 12
    var body: some View {
        Circle().fill(Color(red: 0.2, green: 0.78, blue: 0.35))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Theme.background, lineWidth: size * 0.2))
    }
}

extension Presence {
    /// "Active now", "Active 12m ago", "Active yesterday", as Instagram words it; nil when unknown
    /// or longer ago than Instagram shows.
    var statusText: String? {
        if isActive { return "Active now" }
        guard let t = lastActive else { return nil }
        let s = Date.now.timeIntervalSince(t)
        if s < 60 { return "Active just now" }
        if s < 3600 { return "Active \(Int(s / 60))m ago" }
        if s < 86_400 { return "Active \(Int(s / 3600))h ago" }
        if s < 2 * 86_400 { return "Active yesterday" }
        return nil
    }
}
