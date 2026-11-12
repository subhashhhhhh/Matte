import SwiftUI

/// Something in a chat that can be opened large: a shared post or reel, or a photo or video
/// sent straight into the chat.
enum ViewerRequest: Hashable {
    case share(DMShare)
    case attachment(DMAttachment)
}

extension EnvironmentValues {
    /// Opens a shared item in the Messages side pane (nil outside Messages: links open in the browser).
    @Entry var openInViewer: ((ViewerRequest) -> Void)? = nil
}

/// One openable item in the open chat, newest first.
struct SharedItem: Identifiable, Hashable {
    var id: String
    var request: ViewerRequest
    var preview: URL?
    var isVideo: Bool
    var isReel: Bool
    var sentAt: Date

    static func items(in messages: [DMMessage]) -> [SharedItem] {
        var out: [SharedItem] = []
        for m in messages.reversed() {
            switch m.body {
            case .share(let s, _) where s.mediaPk != nil:
                out.append(SharedItem(id: m.id, request: .share(s), preview: s.preview, isVideo: s.isReel,
                                      isReel: s.isReel, sentAt: m.sentAt))
            case .media(let attachments):
                for (i, a) in attachments.enumerated() where a.kind == .image || a.kind == .video {
                    out.append(SharedItem(id: "\(m.id)#\(i)", request: .attachment(a), preview: a.preview ?? a.url,
                                          isVideo: a.kind == .video, isReel: false, sentAt: m.sentAt))
                }
            default: break
            }
        }
        return out
    }
}

/// The third column in Messages: everything shared in the open chat as a grid, or one item
/// playing large with its caption and comments, while the conversation stays beside it.
struct SharedPane: View {
    let conversation: ConversationModel?
    let items: [SharedItem]
    let viewer: MediaDetailModel?
    let viewerItemId: String?
    let open: (SharedItem) -> Void
    let close: () -> Void
    /// How many shared items to have loaded: grows by a batch each time the grid's end shows.
    @State private var target = Self.batch
    @State private var exhausted = false
    static let batch = 15

    var body: some View {
        content
            .task(id: FillKey(thread: conversation?.thread.id, target: target, loaded: conversation?.isLoading == false)) {
                await fill()
            }
            .onChange(of: conversation?.thread.id) { target = Self.batch; exhausted = false }
    }

    private struct FillKey: Equatable { var thread: String?; var target: Int; var loaded: Bool }

    /// Loads older messages until the chat has `target` shared items or no history is left;
    /// gives up after 8 pages in a row with no share (a "Load more" button takes over).
    private func fill() async {
        guard let conversation, !conversation.isLoading else { return }
        var barren = 0
        while !Task.isCancelled, conversation.hasOlder, !exhausted {
            let count = SharedItem.items(in: conversation.messages).count
            guard count < target else { break }
            // The chat itself may be loading a page: wait for it rather than count it.
            if conversation.loadingOlder {
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            await conversation.loadOlder()
            barren = SharedItem.items(in: conversation.messages).count > count ? 0 : barren + 1
            if barren >= 8 { exhausted = true }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let viewer {
            SharedViewer(model: viewer, position: position, open: open, close: close)
                .id(viewer.id)
        } else {
            gallery
        }
    }

    private var position: (previous: SharedItem?, next: SharedItem?) {
        guard let i = items.firstIndex(where: { $0.id == viewerItemId }) else { return (nil, nil) }
        return (i > 0 ? items[i - 1] : nil, i + 1 < items.count ? items[i + 1] : nil)
    }

    private var gallery: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Shared").font(.system(size: 15, weight: .bold))
                if !items.isEmpty {
                    Text("\(items.count)").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if conversation == nil {
                EmptyState(symbol: "square.grid.2x2", title: "Nothing open",
                           message: "Reels, posts and photos from a chat show up here.")
            } else if items.isEmpty, conversation?.isLoading == false, conversation?.hasOlder == false {
                EmptyState(symbol: "square.grid.2x2", title: "Nothing shared yet",
                           message: "Reels, posts and photos sent in this chat show up here.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 4)], spacing: 4) {
                        ForEach(items) { item in
                            SharedThumb(item: item)
                                .onTapGesture { open(item) }
                                .contextMenu { SharedItemMenu(item: item) { open(item) } }
                        }
                    }
                    .padding(8)
                    if let conversation, conversation.hasOlder {
                        if exhausted {
                            // Many pages in a row without a share: stop paging on its own.
                            Button("Load more") { exhausted = false; target = items.count + Self.batch }
                                .buttonStyle(SecondaryPillStyle())
                                .padding(.vertical, 14)
                        } else {
                            // Reaching the end asks for the next batch (re-armed as items arrive).
                            Spinner(size: 14)
                                .padding(.vertical, 14)
                                .id(items.count)
                                .onAppear { target = max(target, items.count + Self.batch) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct SharedThumb: View {
    let item: SharedItem
    @State private var hovering = false

    var body: some View {
        RemoteImage(url: item.preview, contentMode: .fill)
            .aspectRatio(item.isReel ? 9.0 / 16 : 1, contentMode: .fill)
            .frame(minWidth: 0, maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if item.isVideo {
                    Image(systemName: item.isReel ? "play.rectangle.on.rectangle.fill" : "play.fill")
                        .font(.system(size: 11)).foregroundStyle(.white).padding(6).shadow(radius: 2)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(hovering ? 0.15 : 0))
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// One shared item, large: media on top, caption and comments below.
private struct SharedViewer: View {
    let model: MediaDetailModel
    let position: (previous: SharedItem?, next: SharedItem?)
    let open: (SharedItem) -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button(action: close) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                        Text("Shared").font(.system(size: 13, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .keyboardShortcut(.cancelAction)
                Spacer()
                ChromeButton("Newer", symbol: "chevron.up", shortcut: .upArrow, modifiers: [.command, .option]) {
                    if let p = position.previous { open(p) }
                }
                .disabled(position.previous == nil)
                ChromeButton("Older", symbol: "chevron.down", shortcut: .downArrow, modifiers: [.command, .option]) {
                    if let n = position.next { open(n) }
                }
                .disabled(position.next == nil)
                if let url = model.webURL {
                    ChromeButton("Open on Instagram", symbol: "arrow.up.right") { NSWorkspace.shared.open(url) }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 56)
            GeometryReader { geo in
                VStack(spacing: 0) {
                    stage(maxWidth: geo.size.width - 24, maxHeight: geo.size.height * 0.64)
                        .padding(.horizontal, 12)
                    MediaDetailsColumn(model: model)
                }
            }
        }
        .task { await model.start() }
    }

    @ViewBuilder
    private func stage(maxWidth: CGFloat, maxHeight: CGFloat) -> some View {
        if let media = model.media {
            let aspect = max(0.5, min(1.91, media.aspect))
            let height = min(maxHeight, maxWidth / aspect)
            MediaStage(media: media)
                .frame(width: height * aspect, height: height)
                .contextMenu { PostMenu(media: media) }
                .frame(maxWidth: .infinity)
        } else if model.failed {
            VStack(spacing: 10) {
                Text("This post isn't available.").font(.system(size: 13, weight: .medium))
                if let url = model.webURL {
                    Button("Open on Instagram") { NSWorkspace.shared.open(url) }.buttonStyle(SecondaryPillStyle())
                }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.placeholder)
                .frame(width: min(maxWidth, maxHeight * 9 / 16), height: maxHeight)
                .overlay { Spinner(size: 18) }
                .frame(maxWidth: .infinity)
        }
    }
}

/// Right-click on a shared item. The post itself isn't loaded yet, so this offers what works
/// without it; opening the item gives the full post menu.
private struct SharedItemMenu: View {
    let item: SharedItem
    let open: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        Button("Open", action: open)
        switch item.request {
        case .share(let share):
            if let url = share.targetURL {
                Divider()
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    app.show("Link copied")
                }
                Button("Open on Instagram") { NSWorkspace.shared.open(url) }
            }
        case .attachment(let a):
            if let url = a.url {
                Divider()
                Button(a.kind == .video ? "Download Video" : "Download Photo") {
                    app.actions?.download(url: url, video: a.kind == .video)
                }
            }
        }
    }
}
