import SwiftUI
import AppKit

/// Like, save, send, copy and download for any post or reel. Likes and saves show at once and
/// are undone if Instagram refuses them; the state is kept by media id so the grid, the opened
/// post and Reels agree.
@Observable
final class PostActions {
    struct State: Equatable {
        var liked: Bool
        var likeCount: Int?
        var saved: Bool
        var reposted = false
        var repostCount: Int?
    }

    private(set) var overrides: [String: State] = [:]
    /// Your repost's note id per media pk, once known (removing a repost takes it).
    @ObservationIgnored private var repostNotes: [String: String] = [:]
    /// Your repost's thought, per media pk (as set in this run).
    private(set) var thoughts: [String: String] = [:]
    /// The post whose "Add a thought…" box should open (right after you repost it).
    var thoughtPrompt: String?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private let client: IGClient

    init(app: AppModel, client: IGClient) {
        self.app = app
        self.client = client
    }

    func state(_ m: Media) -> State {
        overrides[m.pk] ?? State(liked: m.hasLiked, likeCount: m.likeCount, saved: m.hasSaved,
                                 reposted: myNote(in: m) != nil, repostCount: m.repostCount)
    }

    private func myNote(in m: Media) -> String? {
        guard let me = app?.viewerId else { return nil }
        return m.repostNotes.first { $0.userId == me }?.id
    }

    func toggleLike(_ m: Media) {
        let old = state(m)
        var new = old
        new.liked.toggle()
        new.likeCount = old.likeCount.map { max(0, $0 + (new.liked ? 1 : -1)) }
        overrides[m.pk] = new
        Task {
            do { try await client.setLiked(new.liked, media: m) } catch {
                overrides[m.pk] = old
                app?.report(error)
            }
        }
    }

    /// Likes (never unlikes): for double-click, as double-tap does on the phone.
    func like(_ m: Media) { if !state(m).liked { toggleLike(m) } }

    func toggleSave(_ m: Media) {
        let old = state(m)
        var new = old
        new.saved.toggle()
        overrides[m.pk] = new
        Task {
            do {
                try await client.setSaved(new.saved, media: m)
                app?.show(new.saved ? "Saved" : "Removed from saved")
            } catch {
                overrides[m.pk] = old
                app?.report(error)
            }
        }
    }

    /// Reposts to your profile, or removes your repost. Shows at once; undone if Instagram
    /// refuses.
    func toggleRepost(_ m: Media) {
        let old = state(m)
        var new = old
        new.reposted.toggle()
        new.repostCount = old.repostCount.map { max(0, $0 + (new.reposted ? 1 : -1)) } ?? (new.reposted ? 1 : nil)
        overrides[m.pk] = new
        Task {
            do {
                if new.reposted {
                    repostNotes[m.pk] = try await client.repost(media: m)
                    app?.show("Reposted")
                    thoughtPrompt = m.pk
                } else {
                    guard let note = try await repostNote(for: m) else { throw IGError.api("Couldn't find your repost.") }
                    try await client.deleteRepost(noteId: note)
                    repostNotes[m.pk] = nil
                    app?.show("Repost removed")
                }
            } catch {
                overrides[m.pk] = old
                app?.report(error)
            }
        }
    }

    /// Your repost's note id: from this run's repost, the media's own notes, or else the
    /// media read again.
    /// Adds (or changes) the thought on your repost, as instagram.com's "Add a thought…" does.
    func setThought(_ text: String, on m: Media) {
        let old = thoughts[m.pk]
        thoughts[m.pk] = text
        Task {
            do {
                guard let note = try await repostNote(for: m) else { throw IGError.api("Couldn't find your repost.") }
                try await client.updateRepost(noteId: note, text: text)
            } catch {
                thoughts[m.pk] = old
                app?.report(error)
            }
        }
    }

    private func repostNote(for m: Media) async throws -> String? {
        if let id = repostNotes[m.pk] ?? myNote(in: m) { return id }
        return myNote(in: try await client.mediaInfo(pk: m.pk))
    }

    func copyLink(_ m: Media) {
        guard let url = m.shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        app?.show("Link copied")
    }

    func copyCaption(_ m: Media) {
        guard let caption = m.caption else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(caption, forType: .string)
        app?.show("Caption copied")
    }

    /// Saves the photo(s) or video(s) at full size to ~/Downloads.
    func download(_ m: Media) {
        let items = m.children.isEmpty ? [m] : m.children
        let owner = m.user?.username ?? "instagram"
        Task {
            var saved = 0
            for (i, item) in items.enumerated() {
                let video = item.isVideo
                guard let url = video ? item.videos.max(by: { $0.width < $1.width })?.url
                                      : item.images.max(by: { $0.width < $1.width })?.url else { continue }
                let suffix = items.count > 1 ? "-\(i + 1)" : ""
                let name = "\(owner)-\(m.code ?? m.pk)\(suffix).\(video ? "mp4" : "jpg")"
                do {
                    let (temp, _) = try await URLSession.shared.download(from: url)
                    let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                    let dest = downloads.appending(path: name)
                    try? FileManager.default.removeItem(at: dest)
                    try FileManager.default.moveItem(at: temp, to: dest)
                    saved += 1
                } catch {
                    app?.report(error)
                }
            }
            if saved > 0 { app?.show(saved == 1 ? "Saved to Downloads" : "\(saved) files saved to Downloads") }
        }
    }

    func send(_ m: Media) { app?.sharing = m }
}

extension Media {
    /// The link Instagram's own "Copy link" gives: /reel/ for reels, /p/ otherwise.
    var shareURL: URL? {
        guard let code else { return nil }
        return URL(string: "https://www.instagram.com/\(productType == "clips" ? "reel" : "p")/\(code)/")
    }
}

// MARK: - Action bar

/// Heart, comment, send and save, as under every Instagram post.
struct PostActionBar: View {
    let media: Media
    var size: CGFloat = 22
    var onComment: (() -> Void)?
    @Environment(AppModel.self) private var app

    var body: some View {
        if let actions = app.actions {
            let state = actions.state(media)
            HStack(spacing: size * 0.65) {
                HStack(spacing: 5) {
                    LikeButton(liked: state.liked, size: size) { actions.toggleLike(media) }
                    if !media.countsHidden, let n = state.likeCount, n > 0 { count(n) }
                }
                HStack(spacing: 5) {
                    iconButton(.comment, help: "Comments") { onComment?() }
                    if let n = media.commentCount, n > 0 { count(n) }
                }
                HStack(spacing: 5) {
                    RepostButton(reposted: state.reposted, size: size) { actions.toggleRepost(media) }
                    if let n = state.repostCount, n > 0 { count(n) }
                }
                iconButton(.share, help: "Send to…") { actions.send(media) }
                Spacer(minLength: 0)
                iconButton(state.saved ? .saveFilled : .save, help: state.saved ? "Remove from saved" : "Save") {
                    actions.toggleSave(media)
                }
            }
        }
    }

    private func count(_ n: Int) -> some View {
        Text(n.compact).font(.system(size: size * 0.6, weight: .semibold)).monospacedDigit()
    }

    private func iconButton(_ icon: IGIcon, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            IGGlyph(icon: icon, size: size).contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help(help)
    }
}

/// The heart: outlined, or red and filled once liked, with a small pop.
struct LikeButton: View {
    let liked: Bool
    var size: CGFloat = 22
    let action: () -> Void
    @State private var pop = false

    var body: some View {
        Button {
            if !liked { pop = true }
            action()
        } label: {
            IGGlyph(icon: liked ? .heartFilled : .heart, size: size)
                .foregroundStyle(liked ? AnyShapeStyle(Theme.like) : AnyShapeStyle(.primary))
                .scaleEffect(pop ? 1.25 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help(liked ? "Unlike" : "Like")
        .onChange(of: pop) {
            guard pop else { return }
            Task { try? await Task.sleep(for: .milliseconds(160)); pop = false }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: pop)
    }
}

/// Instagram's repost arrows: green once you've reposted, with the heart's small pop.
struct RepostButton: View {
    let reposted: Bool
    var size: CGFloat = 22
    let action: () -> Void
    @State private var pop = false

    var body: some View {
        Button {
            if !reposted { pop = true }
            action()
        } label: {
            IGGlyph(icon: .repost, size: size)
                .foregroundStyle(reposted ? AnyShapeStyle(Theme.repost) : AnyShapeStyle(.primary))
                .scaleEffect(pop ? 1.25 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help(reposted ? "Remove repost" : "Repost")
        .onChange(of: pop) {
            guard pop else { return }
            Task { try? await Task.sleep(for: .milliseconds(160)); pop = false }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.5), value: pop)
    }
}

// MARK: - Right-click menu

/// What a right-click on a post or reel offers.
struct PostMenu: View {
    let media: Media
    var open: (() -> Void)?
    @Environment(AppModel.self) private var app

    var body: some View {
        if let actions = app.actions {
            let state = actions.state(media)
            if let open { Button("Open", action: open) }
            Button(state.liked ? "Unlike" : "Like") { actions.toggleLike(media) }
            Button(state.saved ? "Remove from Saved" : "Save") { actions.toggleSave(media) }
            Button(state.reposted ? "Remove Repost" : "Repost") { actions.toggleRepost(media) }
            Button("Send to…") { actions.send(media) }
            Divider()
            Button("Copy Link") { actions.copyLink(media) }
            if media.caption?.isEmpty == false { Button("Copy Caption") { actions.copyCaption(media) } }
            if let url = media.shareURL { Button("Open on Instagram") { NSWorkspace.shared.open(url) } }
            Divider()
            Button(media.children.count > 1 ? "Download All (\(media.children.count))" : media.isVideo ? "Download Video" : "Download Photo") {
                actions.download(media)
            }
        }
    }
}


// MARK: - Liked by

/// "Liked by name and others" with up to three overlapping avatars of people you follow, as the
/// Instagram app shows under a post.
struct LikedByLine: View {
    let media: Media
    var avatarSize: CGFloat = 20
    var fontSize: CGFloat = 12.5

    private var name: (text: String, user: User?)? {
        if let u = media.likedBy.first(where: { !$0.username.isEmpty }) { return (u.username, u) }
        if let n = media.topLikers.first { return (n, nil) }
        return nil
    }

    var body: some View {
        if let name {
            HStack(spacing: 8) {
                let faces = Array(media.likedBy.prefix(3))
                if !faces.isEmpty {
                    HStack(spacing: -avatarSize * 0.35) {
                        ForEach(Array(faces.enumerated()), id: \.element.id) { i, user in
                            Avatar(url: user.avatar, size: avatarSize)
                                .overlay(Circle().strokeBorder(Theme.background, lineWidth: 1.5))
                                .zIndex(Double(faces.count - i))
                        }
                    }
                }
                HStack(spacing: 0) {
                    Text("Liked by ").foregroundStyle(.secondary)
                    Text(name.text).fontWeight(.semibold).opensProfile(name.user)
                    if (media.likedByCount ?? media.likeCount ?? 2) > 1 {
                        Text(" and ").foregroundStyle(.secondary)
                        Text("others").fontWeight(.semibold)
                    }
                }
                .font(.system(size: fontSize))
                .lineLimit(1)
            }
        }
    }
}


// MARK: - Repost bubbles

/// Who reposted this, as bubbles over the photo with Instagram's repost badge; yours offers
/// "Add a thought…" (and opens it right after you repost).
struct RepostBubbles: View {
    let media: Media
    @Environment(AppModel.self) private var app
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let actions = app.actions {
            let me = app.viewerId
            let mine = actions.state(media).reposted
            // Your own note counts as yours even if this post's state hasn't caught up (reposted elsewhere).
            let mine = mine || media.repostNotes.contains { $0.userId == me }
            let others = media.repostNotes.filter { $0.userId != me }.prefix(mine ? 4 : 5)
            let myText = actions.thoughts[media.pk] ?? media.repostNotes.first { $0.userId == me }?.text
            HStack(alignment: .bottom, spacing: 10) {
                if mine, let user = app.me {
                    VStack(spacing: 6) {
                        thoughtBubble(myText)
                        bubbleAvatar(user.avatar)
                    }
                }
                ForEach(Array(others), id: \.id) { note in
                    VStack(spacing: 6) {
                        if let text = note.text { Text(text).font(.system(size: 12)).bubble() }
                        bubbleAvatar(note.user?.avatar)
                    }
                    .opensProfile(note.user?.username.isEmpty == false ? note.user : nil)
                }
            }
            .padding(14)
            .animation(Motion.pop, value: mine)
            .onChange(of: actions.thoughtPrompt) {
                if actions.thoughtPrompt == media.pk { editing = true; actions.thoughtPrompt = nil }
            }
        }
    }

    @ViewBuilder
    private func thoughtBubble(_ text: String?) -> some View {
        if editing {
            TextField("Add a thought…", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .frame(width: 170)
                .focused($focused)
                .onSubmit { commit() }
                .onKeyPress(.escape) { editing = false; return .handled }
                .bubble()
                .onAppear { draft = text ?? ""; focused = true }
                .onChange(of: focused) { if !focused { editing = false } }
                .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
        } else {
            Button { editing = true } label: {
                Text(text ?? "Add a thought…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(text == nil ? .secondary : .primary)
                    .lineLimit(2)
                    .frame(maxWidth: 170)
                    .bubble()
            }
            .buttonStyle(.pressable)
            .help(text == nil ? "Add a thought to your repost" : "Edit your thought")
        }
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        guard let actions = app.actions, text != (actions.thoughts[media.pk] ?? "") else { return }
        actions.setThought(text, on: media)
    }

    private func bubbleAvatar(_ url: URL?) -> some View {
        Avatar(url: url, size: 40)
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
            .overlay(alignment: .bottomTrailing) {
                IGGlyph(icon: .repost, size: 11)
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Color(red: 0.55, green: 0.36, blue: 0.96)))
                    .offset(x: 4, y: 4)
            }
    }
}

private extension View {
    /// A speech bubble like Instagram's thought bubbles.
    func bubble() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
            .environment(\.colorScheme, .dark)
    }
}
