import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

struct MessageRow: View {
    let message: DMMessage
    let model: ConversationModel
    var showAvatar: Bool
    @State private var hovering = false
    @State private var picking = false

    private var mine: Bool { message.senderId == model.viewerId }
    static let quickReactions = ["❤️", "😂", "😮", "😢", "😡", "👍"]

    var body: some View {
        if case .notice(let text) = message.body {
            Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.vertical, 6)
                .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .bottom, spacing: 8) {
                if mine { Spacer(minLength: 80) }
                if !mine {
                    Avatar(url: model.user(for: message.senderId)?.avatar, size: 26).opacity(showAvatar ? 1 : 0)
                }
                if mine, hovering { actions }
                VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                    if model.thread.isGroup, !mine, let u = model.user(for: message.senderId), showAvatar {
                        Text(u.username).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 12)
                    }
                    if let reply = message.replyTo { replyQuote(reply) }
                    MessageBody(message: message, mine: mine)
                        .opacity(message.pending ? 0.6 : 1)
                    if !message.reactions.isEmpty { reactions }
                    if message.failed {
                        Button("Not sent. Click to edit and try again.") { model.retry(message) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11)).foregroundStyle(Theme.like)
                    }
                }
                if !mine, hovering { actions }
                if !mine { Spacer(minLength: 80) }
            }
            .padding(.top, message.reactions.isEmpty ? 1 : 3)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            Button { picking.toggle() } label: { Image(systemName: "face.smiling") }
                .buttonStyle(ChromeButtonStyle(size: 26))
                .help("React")
                .popover(isPresented: $picking, arrowEdge: .top) {
                    HStack(spacing: 4) {
                        ForEach(Self.quickReactions, id: \.self) { e in
                            Button { picking = false; Task { await model.toggleReaction(e, on: message) } } label: {
                                Text(e).font(.system(size: 22)).frame(width: 34, height: 34)
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                    .padding(8)
                }
            Button { model.replyingTo = message } label: { Image(systemName: "arrowshape.turn.up.left") }
                .buttonStyle(ChromeButtonStyle(size: 26))
                .help("Reply")
            if !message.pending, !message.id.hasPrefix("local-") {
                Menu {
                    if model.canForward(message) {
                        Button("Forward…") { model.forwarding = message }
                    }
                    if case .text(let t) = message.body {
                        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }
                    }
                    if model.canEdit(message) {
                        Button("Edit") { model.beginEdit(message) }
                    }
                    Button(model.isPinned(message) ? "Unpin" : "Pin") { Task { await model.togglePin(message) } }
                    if mine {
                        Divider()
                        Button("Unsend", role: .destructive) { Task { await model.unsend(message) } }
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 26, height: 26)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
    }

    private func replyQuote(_ reply: DMMessage.ReplyPreview) -> some View {
        Text(reply.text.isEmpty ? "Message" : reply.text)
            .font(.system(size: 12))
            .lineLimit(2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.panelStroke, lineWidth: 1.5))
    }

    private var reactions: some View {
        let grouped = Dictionary(grouping: message.reactions, by: \.emoji)
        return HStack(spacing: 2) {
            ForEach(grouped.keys.sorted(), id: \.self) { e in
                Text(grouped[e]!.count > 1 ? "\(e) \(grouped[e]!.count)" : e).font(.system(size: 12))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Theme.background))
        .overlay(Capsule().strokeBorder(Theme.panelStroke))
        .offset(y: -6)
        .padding(.bottom, -6)
        .onTapGesture { if let first = message.reactions.first { Task { await model.toggleReaction(first.emoji, on: message) } } }
    }
}

/// The bubble itself.
struct MessageBody: View {
    let message: DMMessage
    let mine: Bool
    @Environment(AppModel.self) private var app

    static let mineFill = Color(red: 0.36, green: 0.31, blue: 0.96)

    var body: some View {
        switch message.body {
        case .text(let text):
            bubble(text)
        case .media(let attachments):
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                ForEach(Array(attachments.enumerated()), id: \.offset) { _, a in AttachmentView(attachment: a) }
            }
        case .share(let share, let text):
            VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
                ShareCard(share: share)
                if let text { bubble(text) }
            }
        case .unsupported(let text):
            bubble(text).italic()
        case .notice:
            EmptyView()
        }
    }

    private func bubble(_ text: String) -> some View {
        // Emoji-only messages show large, without a bubble, as on Instagram.
        let emojiOnly = text.count <= 3 && text.unicodeScalars.allSatisfy { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C || $0.value == 0xFE0F || $0.value == 0x200D }
        return Text(LocalizedStringKey(stringLiteral: text))
            .font(.system(size: emojiOnly ? 34 : 14))
            .foregroundStyle(mine && !emojiOnly ? .white : .primary)
            .tint(mine ? .white : Theme.link)
            .textSelection(.enabled)
            .padding(.horizontal, emojiOnly ? 2 : 12)
            .padding(.vertical, emojiOnly ? 0 : 8)
            .background {
                if !emojiOnly {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(mine ? AnyShapeStyle(Self.mineFill) : AnyShapeStyle(Theme.panel))
                }
            }
    }
}

struct AttachmentView: View {
    let attachment: DMAttachment
    @State private var video: LoopingVideo?
    @Environment(\.openInViewer) private var openInViewer

    var body: some View {
        switch attachment.kind {
        case .image, .sticker, .gif:
            let w: CGFloat = attachment.kind == .sticker ? 120 : 240
            if attachment.kind == .gif, let url = attachment.url, url.pathExtension.lowercased() == "mp4" {
                videoBox(url: url, width: w, autoplay: true)
            } else {
                RemoteImage(url: attachment.url ?? attachment.preview, contentMode: .fit)
                    .frame(width: w, height: w / max(0.3, attachment.aspect))
                    .clipShape(RoundedRectangle(cornerRadius: attachment.kind == .sticker ? 0 : 16, style: .continuous))
                    .onTapGesture {
                        if let openInViewer, attachment.kind == .image { openInViewer(.attachment(attachment)) }
                        else if let url = attachment.url { NSWorkspace.shared.open(url) }
                    }
            }
        case .video:
            if let url = attachment.url { videoBox(url: url, width: 240, autoplay: false) }
        case .audio:
            if let url = attachment.url { VoiceNote(url: url, durationMs: attachment.durationMs) }
        }
    }

    private func videoBox(url: URL, width: CGFloat, autoplay: Bool) -> some View {
        ZStack {
            RemoteImage(url: attachment.preview, contentMode: .fill)
            if let video { PlayerLayerView(player: video.player, gravity: .resizeAspectFill) }
            if video == nil {
                Image(systemName: "play.fill").font(.system(size: 18)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Circle().fill(.black.opacity(0.45)))
            }
        }
        .frame(width: width, height: width / max(0.4, attachment.aspect))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if let video { video.tearDown(); self.video = nil } else {
                let v = LoopingVideo(url: url, muted: autoplay || SoundSetting.shared.muted)
                v.play()
                video = v
            }
        }
        .onAppear {
            if autoplay, video == nil { let v = LoopingVideo(url: url, muted: true); v.play(); video = v }
        }
        .onDisappear { video?.tearDown(); video = nil }
    }
}

/// A voice message: play/pause and a progress bar.
struct VoiceNote: View {
    let url: URL
    let durationMs: Int?
    @State private var video: LoopingVideo?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if let video { video.toggle() } else {
                    let v = LoopingVideo(url: url, muted: false, loops: false)
                    v.onFinish = { video?.tearDown(); video = nil }
                    v.play()
                    video = v
                }
            } label: {
                Image(systemName: video?.isPlaying == true ? "pause.fill" : "play.fill").font(.system(size: 13))
                    .frame(width: 30, height: 30).background(Circle().fill(.primary.opacity(0.1)))
            }
            .buttonStyle(.pressable)
            GeometryReader { g in
                Capsule().fill(.primary.opacity(0.15))
                    .overlay(alignment: .leading) { Capsule().fill(.primary.opacity(0.6)).frame(width: g.size.width * (video?.progress ?? 0)) }
            }
            .frame(width: 130, height: 4)
            if let ms = durationMs {
                Text(Duration.milliseconds(ms).formatted(.time(pattern: .minuteSecond))).font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.panel))
        .onDisappear { video?.tearDown(); video = nil }
    }
}

/// A shared post, reel or story.
struct ShareCard: View {
    let share: DMShare
    @State private var hovering = false
    @Environment(\.openInViewer) private var openInViewer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = share.title {
                HStack(spacing: 6) {
                    if let icon = share.headerIcon { Avatar(url: icon, size: 20) }
                    Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                }
                .padding(10)
            }
            if share.preview != nil {
                let aspect = share.previewWidth > 0 && share.previewHeight > 0
                    ? CGFloat(share.previewWidth) / CGFloat(share.previewHeight) : (share.isReel || share.isStory ? 9.0 / 16 : 1)
                RemoteImage(url: share.preview, contentMode: .fill)
                    .frame(width: 220, height: 220 / max(0.5, min(aspect, 1.5)))
                    .clipped()
                    .overlay(alignment: .topTrailing) {
                        if share.isReel {
                            Image(systemName: "play.rectangle.on.rectangle.fill").foregroundStyle(.white).padding(8).shadow(radius: 2)
                        }
                    }
            }
            if let eyebrow = share.eyebrow {
                Text(eyebrow).font(.system(size: 11)).foregroundStyle(.secondary).padding([.horizontal, .top], 10)
            }
            if let caption = share.caption ?? share.subtitle, !caption.isEmpty {
                Text(caption).font(.system(size: 12)).lineLimit(3).padding(10)
            }
        }
        .frame(width: 220, alignment: .leading)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(hovering ? Theme.selected : Theme.panelStroke))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            if let openInViewer, share.mediaPk != nil { openInViewer(.share(share)) }
            else if let url = share.targetURL { NSWorkspace.shared.open(url) }
        }
        .help(share.targetURL == nil ? "" : share.mediaPk != nil && openInViewer != nil ? "Open beside the chat" : "Open on Instagram")
    }
}

/// Photos and videos waiting to be sent, above the message box.
private struct StagedTray: View {
    let model: ConversationModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.staged) { m in
                    RemoteImage(url: m.preview, contentMode: .fill)
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(alignment: .bottomLeading) {
                            if m.isVideo {
                                Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white)
                                    .padding(5).shadow(radius: 2)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            Button { model.unstage(m.id) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 18, height: 18).background(Circle().fill(.black.opacity(0.6)))
                            }
                            .buttonStyle(.pressable)
                            .padding(4)
                            .help("Remove")
                        }
                }
                if model.preparing > 0 {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.panel)
                        .frame(width: 64, height: 64).overlay { Spinner(size: 14) }
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.never)
    }
}

/// Instagram's "photo" glyph (a framed landscape), drawn in the current foreground style.
struct PhotoGlyph: View {
    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height) / 24
            ZStack(alignment: .topLeading) {
                SVGPathShape(path: "M18.44 2.004A3.56 3.56 0 0 1 22 5.564v12.873a3.56 3.56 0 0 1-3.56 3.56H5.568a3.56 3.56 0 0 1-3.56-3.56V5.563a3.56 3.56 0 0 1 3.56-3.56Z M2.004 17.554l3.802-3.804a1.06 1.06 0 0 1 1.502 0l2.84 2.84a1.06 1.06 0 0 0 1.5 0l5.15-5.15a1.06 1.06 0 0 1 1.5 0l3.7 3.7",
                             box: 24)
                    .stroke(style: StrokeStyle(lineWidth: 2 * s, lineCap: .round, lineJoin: .round))
                Circle().frame(width: 3.2 * s, height: 3.2 * s).offset(x: 5 * s, y: 5 * s)
            }
        }
    }
}

/// The message box: Return sends, Option-Return adds a line.
struct Composer: View {
    @Bindable var model: ConversationModel
    @FocusState private var focused: Bool
    @State private var typingStop: Task<Void, Never>?
    @State private var pasteMonitor: Any?

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .movie]
        panel.message = "Photos and videos up to 25 MB"
        panel.prompt = "Add"
        let model = model
        panel.begin { response in
            if response == .OK { model.stage(files: panel.urls) }
        }
    }

    /// Copied photo/video files, or image data, into the tray.
    static func paste(into model: ConversationModel) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let media = urls.filter(OutgoingMedia.isMediaFile)
            if !media.isEmpty { model.stage(files: media); return }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, .init("public.jpeg"), .init("public.heic")] {
            if let data = pb.data(forType: type) { model.stage(imageData: data); return }
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            if let editing = model.editing {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Editing message").font(.system(size: 11, weight: .semibold))
                        Text(editing.previewText).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    ChromeButton("Cancel Edit", symbol: "xmark") { model.cancelEdit() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 10)
            }
            if let reply = model.replyingTo {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying").font(.system(size: 11, weight: .semibold))
                        Text(reply.previewText).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    ChromeButton("Cancel Reply", symbol: "xmark") { model.replyingTo = nil }
                }
                .padding(.horizontal, 10)
            }
            VStack(alignment: .leading, spacing: 0) {
                if !model.staged.isEmpty || model.preparing > 0 { StagedTray(model: model).padding(.top, 10) }
                HStack(alignment: .bottom, spacing: 8) {
                    Button(action: pickFiles) {
                        PhotoGlyph().frame(width: 22, height: 22).frame(width: 30, height: 36)
                    }
                    .buttonStyle(.pressable)
                    .help("Add photos or videos")
                    .disabled(model.staged.count >= ConversationModel.maxStaged || model.editing != nil)
                    TextField(model.staged.isEmpty ? "Message…" : "Add a message…", text: $model.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .lineLimit(1...6)
                        .focused($focused)
                        .onSubmit { Task { await model.send() } }
                        .padding(.vertical, 9)
                    if model.canSend {
                        Button(model.editing == nil ? "Send" : "Save") { Task { await model.send() } }
                            .buttonStyle(.plain)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.link)
                            .padding(.bottom, 9)
                    }
                }
            }
            .padding(.leading, 6)
            .padding(.trailing, 14)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.panelStroke, lineWidth: 1.5))
        }
        .padding(12)
        .onAppear {
            focused = true
            // ⌘V with a copied photo or video file puts it in the tray (text pastes as usual).
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [model] event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v", OutgoingMedia.pasteboardHasMedia() else { return event }
                Composer.paste(into: model)
                return nil
            }
        }
        .onDisappear { if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }; pasteMonitor = nil }
        .onChange(of: model.replyingTo) { if model.replyingTo != nil { focused = true } }
        .onChange(of: model.editing) { if model.editing != nil { focused = true } }
        // Tell the other side we're typing; stop after 4 s without a keystroke, or when cleared.
        .onChange(of: model.draft) { _, draft in
            typingStop?.cancel()
            let typing = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Task { await model.sendTyping(typing) }
            guard typing else { return }
            typingStop = Task {
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { await model.sendTyping(false) }
            }
        }
        .onDisappear {
            typingStop?.cancel()
            Task { await model.sendTyping(false) }
        }
    }
}
