import SwiftUI
import AVFoundation
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
        /// Your collections it's in.
        var collections: Set<String> = []
    }

    /// Your collections, for the save button's list (loaded when first needed).
    private(set) var collections: [SavedCollection]?
    @ObservationIgnored private var collectionsTask: Task<Void, Never>?

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
                                 reposted: myNote(in: m) != nil, repostCount: m.repostCount,
                                 collections: Set(m.savedCollectionIds ?? []))
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

    func loadCollections(force: Bool = false) {
        guard force || (collections == nil && collectionsTask == nil) else { return }
        collectionsTask = Task {
            defer { collectionsTask = nil }
            do { collections = try await client.collectionPicker() } catch {
                if collections == nil { app?.report(error) }
            }
        }
    }

    /// Puts the post in a collection or takes it out (the save button's list). Adding saves it
    /// first if it isn't, as instagram.com does; taking it out leaves it saved.
    func toggleCollection(_ id: String, media m: Media) {
        let old = state(m)
        var new = old
        let adding = !old.collections.contains(id)
        if adding { new.collections.insert(id); new.saved = true } else { new.collections.remove(id) }
        overrides[m.pk] = new
        let name = collections?.first { $0.id == id }?.name ?? "collection"
        Task {
            var savedNow = false
            do {
                if adding {
                    if !old.saved {
                        try await client.setSaved(true, media: m)
                        savedNow = true
                    }
                    try await client.addToCollection(id, media: m)
                    app?.show("Saved to \(name)")
                } else {
                    try await client.removeFromCollection(id, media: m)
                    app?.show("Removed from \(name)")
                }
            } catch {
                // Undo only what failed: a save that went through stays shown as saved.
                var back = old
                if savedNow { back.saved = true }
                overrides[m.pk] = back
                app?.report(error)
            }
        }
    }

    /// A new collection with the post in it (and the post saved), as instagram.com makes one.
    func createCollection(named title: String, with m: Media) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let old = state(m)
        Task {
            let id: String
            do { id = try await client.createCollection(named: title, with: m) } catch {
                app?.report(error)
                return
            }
            // The collection exists (with the post in it) even if the save after it fails.
            var new = state(m)
            new.collections.insert(id)
            collections = [SavedCollection(id: id, name: title, cover: m.image(minWidth: 120))] + (collections ?? [])
            var saveFailed: Error?
            if !old.saved {
                do { try await client.setSaved(true, media: m) } catch { saveFailed = error }
            }
            if saveFailed == nil { new.saved = true }
            overrides[m.pk] = new
            if let saveFailed { app?.report(saveFailed) } else { app?.show("Saved to \(title)") }
        }
    }

    func toggleSave(_ m: Media) {
        let old = state(m)
        var new = old
        new.saved.toggle()
        // Unsaving takes it out of every collection too.
        if !new.saved { new.collections = [] }
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

    // MARK: Your own posts

    /// Commenting turned off (true) or on (false) in this run, per pk.
    private(set) var commentsOff: [String: Bool] = [:]
    /// Captions edited in this run, per pk.
    private(set) var captions: [String: String] = [:]

    func isMine(_ m: Media) -> Bool {
        guard let me = app?.viewerId, let owner = m.user?.id else { return false }
        return owner == me && m.expiresAt == nil
    }

    func caption(_ m: Media) -> String? { captions[m.pk] ?? m.caption }

    func commentsDisabled(_ m: Media) -> Bool { commentsOff[m.pk] ?? m.commentsDisabled ?? false }

    /// Turns commenting on or off for your post; shows at once, undone if Instagram refuses.
    func setCommenting(_ enabled: Bool, on m: Media) {
        let old = commentsOff[m.pk]
        commentsOff[m.pk] = !enabled
        Task {
            do {
                try await client.setCommentsEnabled(enabled, pk: m.pk)
                app?.show(enabled ? "Commenting turned on" : "Commenting turned off")
            } catch {
                commentsOff[m.pk] = old
                app?.report(error)
            }
        }
    }

    /// Saves a new caption for your post. True when Instagram took it.
    func saveCaption(_ text: String, for m: Media) async -> Bool {
        do {
            try await client.editCaption(text, media: m)
            captions[m.pk] = text
            MediaDetailModel.updateCaption(pk: m.pk, text: text)
            app?.show("Caption updated")
            return true
        } catch {
            app?.report(error)
            return false
        }
    }

    /// Deletes your post or reel (after the dialog's confirmation).
    func delete(_ m: Media) async -> Bool {
        do {
            try await client.deletePost(pk: m.pk)
            app?.removedPost(m.pk)
            app?.show(m.productType == "clips" ? "Reel deleted" : "Post deleted")
            return true
        } catch {
            app?.report(error)
            return false
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
                guard let url = video ? item.bestVideoURL : item.bestImageURL else { continue }
                let suffix = items.count > 1 ? "-\(i + 1)" : ""
                if await save(url, as: "\(owner)-\(m.code ?? m.pk)\(suffix).\(video ? "mp4" : "jpg")") { saved += 1 }
            }
            if saved > 0 { app?.show(saved == 1 ? "Saved to Downloads" : "\(saved) files saved to Downloads") }
        }
    }

    /// Saves one file (a story item, a DM photo or video) to Downloads.
    func download(url: URL, video: Bool, name: String? = nil) {
        let file = (name ?? "instagram-\(Int(Date.now.timeIntervalSince1970))") + (video ? ".mp4" : ".jpg")
        Task { if await save(url, as: file) { app?.show("Saved to Downloads") } }
    }

    /// Saves one frame of a video as a photo (a video story "as a photo").
    func downloadFrame(of url: URL, at seconds: Double, name: String) {
        Task {
            do {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                let (image, _) = try await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
                let rep = NSBitmapImageRep(cgImage: image)
                guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) else { return }
                let dest = try Self.downloads().appending(path: name + ".jpg")
                try? FileManager.default.removeItem(at: dest)
                try data.write(to: dest)
                app?.show("Saved to Downloads")
            } catch {
                app?.report(error)
            }
        }
    }

    private func save(_ url: URL, as name: String) async -> Bool {
        do {
            let (temp, _) = try await URLSession.shared.download(from: url)
            let dest = try Self.downloads().appending(path: name)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temp, to: dest)
            return true
        } catch {
            app?.report(error)
            return false
        }
    }

    private static func downloads() throws -> URL {
        try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    func send(_ m: Media) { app?.sharing = m }
}

extension Media {
    var bestVideoURL: URL? { videos.max(by: { $0.width < $1.width })?.url }
    var bestImageURL: URL? { images.max(by: { $0.width < $1.width })?.url }

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
                SaveButton(media: media, size: size)
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
            if actions.isMine(media) {
                Divider()
                Button("Edit Caption") { app.editingCaption = media }
                if actions.commentsDisabled(media) {
                    Button("Turn On Commenting") { actions.setCommenting(true, on: media) }
                } else {
                    Button("Turn Off Commenting") { actions.setCommenting(false, on: media) }
                }
                Button(media.productType == "clips" ? "Delete Reel…" : "Delete Post…", role: .destructive) { app.confirmingDelete = media }
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
    /// Smaller, for feed cards and the Reels player (fewer people, smaller avatars).
    var compact = false
    @Environment(AppModel.self) private var app
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if let actions = app.actions {
            let me = app.viewerId
            // Your own note counts as yours even if this post's state hasn't caught up (reposted elsewhere).
            let mine = actions.state(media).reposted || media.repostNotes.contains { $0.userId == me }
            let limit = compact ? 3 : 5
            let others = media.repostNotes.filter { $0.userId != me }.prefix(mine ? limit - 1 : limit)
            let myText = actions.thoughts[media.pk] ?? media.repostNotes.first { $0.userId == me }?.text
            HStack(alignment: .bottom, spacing: compact ? 6 : 10) {
                if mine, let user = app.me {
                    VStack(spacing: 6) {
                        thoughtBubble(myText)
                        bubbleAvatar(user.avatar)
                    }
                }
                ForEach(Array(others), id: \.id) { note in
                    VStack(spacing: 6) {
                        if let text = note.text {
                            Text(text).font(.system(size: compact ? 11 : 12)).lineLimit(compact ? 2 : nil)
                                .frame(maxWidth: compact ? 120 : nil).bubble()
                        }
                        bubbleAvatar(note.user?.avatar)
                    }
                    .opensProfile(note.user?.username.isEmpty == false ? note.user : nil)
                }
            }
            .padding(compact ? 10 : 14)
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
                .frame(width: compact ? 140 : 170)
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
                    .frame(maxWidth: compact ? 140 : 170)
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
        Avatar(url: url, size: compact ? 28 : 40)
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: compact ? 1.5 : 2))
            .overlay(alignment: .bottomTrailing) {
                IGGlyph(icon: .repost, size: compact ? 8 : 11)
                    .foregroundStyle(.white)
                    .frame(width: compact ? 14 : 20, height: compact ? 14 : 20)
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
