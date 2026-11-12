import SwiftUI
import OSLog

/// The DM inbox and the open conversation.
@Observable
final class InboxModel {
    private(set) var threads: [DMThread] = [] {
        didSet {
            if !Self.isTesting { DMNotifier.setBadge(unreadCount) }
            if !stale { scheduleSave() }
        }
    }
    /// `threads` came from the cache: shown until the first fresh inbox replaces them.
    @ObservationIgnored private(set) var stale = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    static let cachedThreads = 30
    private(set) var isLoading = false
    private(set) var loadFailed = false
    var selectedId: String? {
        didSet { if selectedId != oldValue { openSelected() } }
    }
    private(set) var conversation: ConversationModel?
    var unreadCount: Int { threads.filter(\.isUnread).count }

    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var hasMore = false
    @ObservationIgnored private(set) var seqId: String?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored let client: IGClient
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var loadedOnce = false
    /// True while the real-time socket is subscribed (polling pauses meanwhile).
    private(set) var isLive = false
    /// The real-time DM connection (docs/dm-protocol.md §5), once the inbox gave a seq id.
    @ObservationIgnored private(set) var realtime: DMRealtime?
    @ObservationIgnored private var realtimeTask: Task<Void, Never>?
    /// After the gateway refused the session (and a normal request showed it's fine): when to try again.
    @ObservationIgnored private var realtimeRetryAt = Date.distantPast
    @ObservationIgnored private var inboxRefresh: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "com.subhash.Instagram", category: "DMs")

    init(app: AppModel, client: IGClient) {
        self.app = app
        self.client = client
        // The last inbox shows at once (the fresh one replaces it).
        if let hit = app.cache?.load([DMThread].self, "inbox", maxAge: 14 * 86_400)?.value, !hit.isEmpty {
            stale = true
            threads = hit
        }
        guard !Self.isTesting else { return }
        // Messages arrive (and notify) whichever page is open: load the inbox and connect the
        // real-time socket shortly after launch.
        DMNotifier.shared.open = { [weak self] id in self?.openFromNotification(id) }
        DMNotifier.shared.start()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.loadIfNeeded()
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
    }

    /// Unit tests build models without the app around them: no notifications, Dock badge or
    /// background loading there.
    nonisolated static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
    @ObservationIgnored private var activeObserver: NSObjectProtocol?

    private func openFromNotification(_ threadId: String) {
        app?.openChat(threadId)
        DMNotifier.shared.clear(thread: threadId)
    }

    /// Back in the app: the open chat counts as seen now.
    private func appBecameActive() {
        guard let conversation, app?.destination == .messages else { return }
        DMNotifier.shared.clear(thread: conversation.thread.id)
        Task { await conversation.markReadIfVisible() }
    }

    /// Whether you're looking at this chat right now (the app in front, on Messages, chat open).
    func isWatching(_ threadId: String) -> Bool {
        NSApp.isActive && app?.destination == .messages && conversation?.thread.id == threadId
            && NSApp.keyWindow != nil
    }

    /// A notification for a new message from someone else, unless you're looking at that chat.
    private func notifyIfNeeded(_ threadId: String, _ message: DMMessage) async {
        guard !Self.isTesting, !isWatching(threadId), Date.now.timeIntervalSince(message.sentAt) < 600 else { return }
        var thread = threads.first { $0.id == threadId }
        if thread == nil {
            await refresh()
            thread = threads.first { $0.id == threadId }
        }
        guard let thread, !thread.isMuted else { return }
        // Not our own messages (sent from another device, echoed back).
        let me: String? = if let id = thread.viewerMessagingId { id } else { await client.page.messagingId }
        guard let me, message.senderId != me else { return }
        if case .notice = message.body { return }
        DMNotifier.shared.notify(thread: thread, message: message, sender: thread.users.first { $0.messagingId == message.senderId })
    }

    var selected: DMThread? {
        threads.first { $0.id == selectedId } ?? requests.first { $0.id == selectedId } ?? hiddenRequests.first { $0.id == selectedId }
    }

    // MARK: Message requests

    /// Chats from people you don't follow, waiting to be accepted, and hidden ones (Instagram's filter).
    private(set) var requests: [DMThread] = []
    private(set) var hiddenRequests: [DMThread] = []
    private(set) var loadingRequests = false
    @ObservationIgnored private var requestsLoadedAt: Date?

    func loadRequests(force: Bool = false) async {
        if !force, let t = requestsLoadedAt, Date.now.timeIntervalSince(t) < 60 { return }
        loadingRequests = true
        defer { loadingRequests = false }
        do {
            let r = try await client.messageRequests()
            requests = r.requests
            hiddenRequests = r.hidden
            requestsLoadedAt = .now
        } catch {
            app?.report(error)
        }
    }

    /// Accepts a request: it moves to the inbox (you can reply, and they see when you've read).
    func accept(_ thread: DMThread) async {
        do {
            try await client.acceptRequest(thread.id)
            requests.removeAll { $0.id == thread.id }
            hiddenRequests.removeAll { $0.id == thread.id }
            var t = thread
            t.isRequest = false
            merge([t])
            conversation?.markAccepted()
            await refresh()
        } catch {
            app?.report(error)
        }
    }

    // MARK: New chat

    /// Someone you picked in "New message" who has no chat with you yet (the chat starts with
    /// your first message).
    private(set) var newChatUser: User?

    /// Opens the chat with `user`: their existing one-to-one chat if there is one, else a new one.
    func startChat(with user: User) {
        if let t = (threads + requests).first(where: { !$0.isGroup && $0.users.first?.id == user.id }) {
            newChatUser = nil
            selectedId = t.id
            return
        }
        selectedId = nil
        newChatUser = user
    }

    func cancelNewChat() { newChatUser = nil }

    /// Sends the first message to `newChatUser`, then opens the chat it created.
    func sendFirstMessage(_ text: String) async -> Bool {
        guard let user = newChatUser, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do {
            try await client.startChat(with: user.id, text: text)
        } catch {
            app?.report(error)
            return false
        }
        // The new chat shows up in the inbox once Instagram has it.
        for delay in [0.5, 1.5, 3.0] {
            try? await Task.sleep(for: .seconds(delay))
            await refresh()
            if let t = threads.first(where: { !$0.isGroup && $0.users.first?.id == user.id }) {
                newChatUser = nil
                selectedId = t.id
                return true
            }
        }
        newChatUser = nil
        return true
    }

    func loadIfNeeded() async {
        guard !loadedOnce else { return }
        loadedOnce = true
        await refresh()
        startRealtime()
        startPolling()
        #if DEBUG
        // `-IGTestNotification YES`: post a local notification for the first chat (checks the
        // notification and click-to-open path; nothing is sent to Instagram).
        if UserDefaults.standard.bool(forKey: "IGTestNotification"), let t = threads.first {
            let other = t.users.first?.messagingId ?? "0"
            DMNotifier.shared.notify(thread: t, message: DMMessage(id: "test-\(Int(Date.now.timeIntervalSince1970))", senderId: other,
                                                                   sentAt: .now, body: .text("Test notification")),
                                     sender: t.users.first)
            try? await Task.sleep(for: .seconds(2))
            DMNotifier.shared.logDelivered()
        }
        #endif
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let box = try await client.inbox()
            if stale {
                // Cached chats Instagram no longer lists (deleted, left, moved to requests) go;
                // the open one stays until you leave it.
                let fresh = Set(box.threads.map(\.id))
                stale = false
                threads.removeAll { !fresh.contains($0.id) && $0.id != selectedId }
            }
            merge(box.threads)
            cursor = box.cursor
            hasMore = box.hasMore
            seqId = box.seqId
            loadFailed = false
        } catch {
            loadFailed = threads.isEmpty
            app?.report(error)
        }
    }

    func loadMore() async {
        guard hasMore, let cursor, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await client.olderThreads(cursor: cursor)
            merge(page.threads)
            self.cursor = page.cursor
            hasMore = page.hasMore
        } catch {
            app?.report(error)
        }
    }

    /// Updates threads in place (new activity moves a thread to the top).
    private func merge(_ fresh: [DMThread]) {
        var byId = Dictionary(threads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for t in fresh {
            var t = t
            // The open thread is read as it arrives.
            if t.id == selectedId { t.isUnread = false }
            byId[t.id] = t
        }
        threads = byId.values.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
        if fresh.count > 1 { watchPresence() }
    }

    /// Saves the top of the inbox a few seconds after it changes (bursts of updates write once).
    private func scheduleSave() {
        guard let cache = app?.cache else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            cache.save(Array(threads.filter { !$0.isRequest }.prefix(Self.cachedThreads)), "inbox")
        }
    }

    /// The open thread's newest state (after sending, or a poll).
    func update(_ thread: DMThread) { merge([thread]) }

    private func openSelected() {
        conversation?.stop()
        conversation = nil
        guard let thread = selected else { return }
        newChatUser = nil
        conversation = ConversationModel(inbox: self, thread: thread, client: client)
        if let i = threads.firstIndex(where: { $0.id == thread.id }) { threads[i].isUnread = false }
        if !Self.isTesting { DMNotifier.shared.clear(thread: thread.id) }
    }

    func report(_ error: Error) { app?.report(error) }
    func show(_ message: String) { app?.show(message) }

    // MARK: Real-time

    private func startRealtime() {
        guard realtime == nil, Date.now >= realtimeRetryAt, let seq = seqId.flatMap(Int64.init) else { return }
        let rt = DMRealtime(client: client, seqId: seq)
        realtime = rt
        watchPresence()
        realtimeTask = Task { [weak self] in
            await rt.start()
            for await event in rt.events {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    private func stopRealtime() {
        let rt = realtime
        realtime = nil
        realtimeTask?.cancel()
        realtimeTask = nil
        isLive = false
        Task { await rt?.stop() }
    }

    private func handle(_ event: DMRealtimeEvent) async {
        switch event {
        case .connected:
            isLive = true
        case .disconnected:
            isLive = false
        case .unauthorized:
            // Check with an ordinary request: a dead session signs out through `report`;
            // otherwise keep polling and try the socket again later.
            // (Outside this event loop's task, which stopping cancels.)
            stopRealtime()
            realtimeRetryAt = .now.addingTimeInterval(600)
            Task { [weak self] in await self?.refresh() }
        case .resnapshot:
            // Our cursor is too old: take a new snapshot and resume from it.
            let old = seqId
            await refresh()
            if let seq = seqId.flatMap(Int64.init), seqId != old {
                await realtime?.restart(seqId: seq)
            } else {
                // No new snapshot (offline?): poll, and the poll loop reconnects later.
                stopRealtime()
            }
        case .message(let id, let message):
            conversation(id)?.receive(message)
            bumpRow(id, with: message)
            await notifyIfNeeded(id, message)
        case .messageDeleted(let id, let messageId):
            conversation(id)?.remove(messageId)
            refreshInboxSoon()
        case .messageEdited(let id, _, _), .reaction(let id, _, _, _):
            conversation(id)?.refreshSoon()
        case .readReceipt(let id, let who, let at):
            conversation(id)?.applyReadReceipt(who, at: at)
            if let i = threads.firstIndex(where: { $0.id == id }), (threads[i].readUpTo[who] ?? .distantPast) < at {
                threads[i].readUpTo[who] = at
            }
        case .markedRead(let id):
            if let i = threads.firstIndex(where: { $0.id == id }) { threads[i].isUnread = false }
        case .typing(let longId, _, let typing):
            if let c = conversation, c.thread.longId == longId { c.setPeerTyping(typing) }
        case .threadChanged(let id):
            conversation(id)?.refreshSoon()
            refreshInboxSoon()
        case .presence(let updates, let full):
            // Like the web app: a full publish replaces the list, an incremental one patches it.
            if full { presence = updates } else { presence.merge(updates) { $1 } }
        }
    }

    // MARK: Presence

    /// People's activity status by messaging id (`User.messagingId`), live from the presence
    /// stream. Covers the server's own list plus everyone in the loaded threads, which are
    /// asked for (like the web app does) as threads load.
    private(set) var presence: [String: Presence] = [:]

    /// A thread's status as the web app words it: active if anyone else in it is active;
    /// otherwise, for a one-to-one chat, when the other person was last active.
    func presence(for thread: DMThread) -> Presence? {
        let others = thread.users.compactMap(\.messagingId).filter { $0 != thread.viewerMessagingId }
        let known = others.compactMap { presence[$0] }
        if let active = known.first(where: \.isActive) { return active }
        guard !thread.isGroup, let first = others.first else { return nil }
        return presence[first]
    }

    /// Asks the presence stream for everyone in the loaded threads.
    private func watchPresence() {
        guard let realtime else { return }
        let ids = threads.flatMap { t in t.users.compactMap(\.messagingId).filter { $0 != t.viewerMessagingId } }
        Task { await realtime.watchPresence(ids) }
    }

    private func conversation(_ threadId: String) -> ConversationModel? {
        conversation?.thread.id == threadId ? conversation : nil
    }

    /// A new message moves its thread to the top with a new snippet (no request); an unknown
    /// thread means fetching the inbox again.
    private func bumpRow(_ id: String, with message: DMMessage) {
        guard let i = threads.firstIndex(where: { $0.id == id }) else { refreshInboxSoon(); return }
        var row = threads[i]
        if let last = row.lastActivity, message.sentAt < last { return }
        row.lastActivity = message.sentAt
        row.snippet = message.previewText
        row.lastSenderIsViewer = message.senderId == row.viewerMessagingId
        if !row.lastSenderIsViewer { row.isUnread = true }
        merge([row])
    }

    /// Fetches the inbox's first page once a burst of changes has settled.
    private func refreshInboxSoon() {
        inboxRefresh?.cancel()
        inboxRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: Fallback polling (only while the socket is down)

    private func startPolling() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                if self.isLive { continue }
                await self.conversation?.poll()
                await self.refresh()
                self.startRealtime()
            }
        }
    }

    func stop() {
        poller?.cancel()
        saveTask?.cancel()
        inboxRefresh?.cancel()
        stopRealtime()
        conversation?.stop()
    }
}

/// One conversation: messages oldest first (for display), older pages on demand, sending.
@Observable
final class ConversationModel {
    private(set) var thread: DMThread
    private(set) var messages: [DMMessage] = []
    private(set) var isLoading = false
    private(set) var loadingOlder = false
    private(set) var hasOlder = false
    var draft = ""
    var replyingTo: DMMessage?
    /// Bumped when new messages arrive at the bottom (the view scrolls to them).
    private(set) var newestToken = 0
    /// Someone else in the thread is typing (from the real-time socket; clears itself after 6 s).
    private(set) var peerTyping = false

    @ObservationIgnored private var typingExpiry: Task<Void, Never>?
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var sentTyping: (on: Bool, at: Date)?

    @ObservationIgnored private var olderCursor: String?
    @ObservationIgnored private weak var inbox: InboxModel?
    @ObservationIgnored private let client: IGClient
    @ObservationIgnored private var markedReadUpTo: String?

    init(inbox: InboxModel, thread: DMThread, client: IGClient) {
        self.inbox = inbox
        self.thread = thread
        self.client = client
        Task { await load() }
    }

    var viewerId: String? { thread.viewerMessagingId }

    func user(for messagingId: String) -> User? {
        thread.users.first { $0.messagingId == messagingId }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let r = try await client.thread(thread.id)
            if let t = r.thread { thread = merged(t) }
            messages = r.messages.items.reversed()
            olderCursor = r.messages.cursor
            hasOlder = r.messages.hasMore
            newestToken += 1
            await markRead()
        } catch {
            inbox?.report(error)
        }
    }

    /// Keeps what the inbox knows that the detail query leaves out.
    private func merged(_ t: DMThread) -> DMThread {
        var t = t
        if t.viewerMessagingId == nil { t.viewerMessagingId = thread.viewerMessagingId }
        if t.users.isEmpty { t.users = thread.users }
        t.isMuted = thread.isMuted
        t.isPinned = thread.isPinned
        if thread.isRequest { t.isRequest = true }
        t.isUnread = false
        return t
    }

    func loadOlder() async {
        guard hasOlder, let olderCursor, !loadingOlder else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await client.olderMessages(thread: thread.id, cursor: olderCursor)
            let known = Set(messages.map(\.id))
            messages.insert(contentsOf: page.items.reversed().filter { !known.contains($0.id) }, at: 0)
            self.olderCursor = page.cursor
            hasOlder = page.hasMore
        } catch {
            inbox?.report(error)
        }
    }

    /// Fetches the newest messages and adds any we don't have.
    func poll() async {
        guard !isLoading else { return }
        guard let r = try? await client.thread(thread.id) else { return }
        if let t = r.thread { thread = merged(t) }
        let fresh = r.messages.items.reversed()
        var changed = false
        for m in fresh {
            if let i = messages.firstIndex(where: { $0.id == m.id || ($0.offlineId != nil && $0.offlineId == m.offlineId) }) {
                if messages[i] != m { messages[i] = m; changed = true }
            } else {
                messages.append(m)
                changed = true
            }
        }
        if changed {
            messages.sort { $0.sentAt < $1.sentAt }
            newestToken += 1
            await markReadIfVisible()
        }
    }

    // MARK: Real-time updates

    /// A message from the socket: replaces our pending copy (same offline id) or is added.
    func receive(_ message: DMMessage) {
        if let i = messages.firstIndex(where: { $0.id == message.id || ($0.offlineId != nil && $0.offlineId == message.offlineId) }) {
            var m = message
            if m.replyTo == nil { m.replyTo = messages[i].replyTo }
            if messages[i] != m { messages[i] = m }
        } else {
            messages.append(message)
            if messages.count > 1, messages[messages.count - 2].sentAt > message.sentAt { messages.sort { $0.sentAt < $1.sentAt } }
            newestToken += 1
        }
        if message.senderId != viewerId {
            setPeerTyping(false)
            Task { await markReadIfVisible() }
        }
    }

    /// Marks the chat read only while you can see it (the app in front); otherwise when you
    /// come back to it.
    func markReadIfVisible() async {
        guard InboxModel.isTesting || inbox?.isWatching(thread.id) == true else { return }
        await markRead()
    }

    func remove(_ messageId: String) {
        messages.removeAll { $0.id == messageId }
    }

    /// The other side's activity status ("Active now" / "Active 12m ago"): see `InboxModel.presence(for:)`.
    var presence: Presence? { inbox?.presence(for: thread) }

    func applyReadReceipt(_ participant: String, at: Date) {
        if (thread.readUpTo[participant] ?? .distantPast) < at { thread.readUpTo[participant] = at }
    }

    func setPeerTyping(_ typing: Bool) {
        typingExpiry?.cancel()
        if peerTyping != typing { peerTyping = typing }
        guard typing else { return }
        typingExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.peerTyping = false
        }
    }

    /// Refetches the newest messages once a burst of changes (edits, reactions) has settled.
    func refreshSoon() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.poll()
        }
    }

    /// Tells the thread we're typing (`true`) or stopped. Meant to be called as the draft
    /// changes: repeats of the same state within 5 s aren't sent again.
    func sendTyping(_ typing: Bool) async {
        if let last = sentTyping, last.on == typing, !typing || Date.now.timeIntervalSince(last.at) < 5 { return }
        guard let realtime = inbox?.realtime else { return }
        sentTyping = (typing, .now)
        try? await realtime.setTyping(typing, threadId: thread.id)
    }

    // MARK: Actions

    /// Photos and videos waiting in the composer; they go out with the next send.
    private(set) var staged: [StagedMedia] = []
    /// Files still being prepared for the tray.
    private(set) var preparing = 0
    /// Media we sent, by offline id, so a failed one can go back to the tray.
    @ObservationIgnored private var outgoing: [String: StagedMedia] = [:]
    static let maxStaged = 10

    /// Adds photos or videos (picked or dropped files) to the composer.
    func stage(files: [URL]) {
        for url in files.prefix(Self.maxStaged - staged.count) {
            preparing += 1
            Task {
                defer { preparing -= 1 }
                do {
                    let m = try await OutgoingMedia.prepare(file: url)
                    if staged.count < Self.maxStaged { staged.append(m) }
                } catch {
                    inbox?.report(error)
                }
            }
        }
    }

    /// Adds a pasted image to the composer.
    func stage(imageData: Data) {
        guard staged.count < Self.maxStaged else { return }
        do { staged.append(try OutgoingMedia.prepare(imageData: imageData)) } catch { inbox?.report(error) }
    }

    func unstage(_ id: UUID) { staged.removeAll { $0.id == id } }

    var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !staged.isEmpty }

    // MARK: Editing and forwarding

    /// Your message being edited in the composer (its text in `draft`).
    private(set) var editing: DMMessage?
    /// The message the "Forward to…" sheet is open for.
    var forwarding: DMMessage?
    /// Instagram lets you edit a message for 15 minutes.
    static let editWindow: TimeInterval = 15 * 60

    func canEdit(_ m: DMMessage) -> Bool {
        guard m.senderId == viewerId, !m.pending, !m.failed, !m.id.hasPrefix("local-"),
              Date.now.timeIntervalSince(m.sentAt) < Self.editWindow, case .text = m.body else { return false }
        return true
    }

    func beginEdit(_ m: DMMessage) {
        guard canEdit(m), case .text(let t) = m.body else { return }
        replyingTo = nil
        editing = m
        draft = t
    }

    func cancelEdit() {
        editing = nil
        draft = ""
    }

    private func finishEdit(_ original: DMMessage) async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        draft = ""
        guard !text.isEmpty, original.body != .text(text) else { return }
        guard let i = messages.firstIndex(where: { $0.id == original.id }) else { return }
        messages[i].body = .text(text)
        messages[i].isEdited = true
        do {
            try await client.editMessage(original.id, thread: thread.id, text: text)
        } catch {
            if let j = messages.firstIndex(where: { $0.id == original.id }) { messages[j] = original }
            inbox?.report(error)
        }
    }

    /// Whether a message can be forwarded (text, photos and videos with an id, shared links).
    func canForward(_ m: DMMessage) -> Bool {
        guard !m.pending, !m.failed, !m.id.hasPrefix("local-") else { return false }
        switch m.body {
        case .text: return true
        case .media(let a): return a.contains { $0.id != nil && ($0.kind == .image || $0.kind == .video) }
        case .share(let s, _): return s.targetURL != nil
        default: return false
        }
    }

    /// Forwards `m` into the chats `targets`; returns how many failed.
    func forward(_ m: DMMessage, to targets: [String]) async -> Int {
        let own = m.senderId == viewerId
        // instagram.com names the source chat by its long id (recorded on a reel forward).
        let origin = thread.longId ?? thread.id
        var failures = 0
        for target in targets {
            do {
                switch m.body {
                case .text(let t):
                    try await client.forwardText(t, from: origin, ownMessage: own, to: target)
                case .media(let attachments):
                    for a in attachments where a.kind == .image || a.kind == .video {
                        guard let id = a.id else { continue }
                        try await client.forwardAttachment(id, messageId: m.id, from: origin, ownMessage: own, to: target)
                    }
                case .share(let s, let text):
                    if !s.isStory, let pk = s.mediaPk {
                        // As instagram.com forwards a shared reel (recorded): the share mutation,
                        // naming the chat it came from. Posts the same way with the media share.
                        var media = Media(id: pk, pk: pk, kind: .image)
                        media.productType = s.isReel ? "clips" : "feed"
                        try await client.share(media, to: .thread(target), forwardedFrom: origin, own: own)
                    } else if let url = s.targetURL {
                        // A shared story goes on as its link (Instagram shows it as a card).
                        try await client.forwardText(url.absoluteString, from: origin, ownMessage: own, to: target)
                    }
                    if let text, !text.isEmpty {
                        try await client.forwardText(text, from: origin, ownMessage: own, to: target)
                    }
                default:
                    break
                }
            } catch {
                failures += 1
                inbox?.report(error)
            }
        }
        return failures
    }

    /// Sends the composer: its photos and videos first (each its own message, shown at once
    /// while it uploads), then the text.
    func send() async {
        if let editing { await finishEdit(editing); return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let media = staged
        guard !text.isEmpty || !media.isEmpty, let viewerId else { return }
        draft = ""
        staged = []
        let reply = replyingTo
        replyingTo = nil
        // Everything appears right away, in order; then goes out one by one.
        var queue: [(otid: String, media: StagedMedia?)] = []
        for m in media { queue.append((OfflineThreadingId.next(), m)) }
        if !text.isEmpty { queue.append((OfflineThreadingId.next(), nil)) }
        // A reply quotes on the text if there is one, else on the first photo.
        let replyOtid = text.isEmpty ? queue.first?.otid : queue.last?.otid
        for item in queue {
            var local = DMMessage(id: "local-\(item.otid)", senderId: viewerId, sentAt: .now,
                                  body: item.media.map { .media([$0.attachment]) } ?? .text(text))
            local.pending = true
            local.offlineId = item.otid
            if let reply, item.otid == replyOtid { local.replyTo = .init(id: reply.id, senderId: reply.senderId, text: reply.previewText) }
            messages.append(local)
            if let m = item.media { outgoing[item.otid] = m }
        }
        newestToken += 1
        for item in queue {
            let replyId = item.otid == replyOtid ? reply?.id : nil
            do {
                let id: String?
                if let m = item.media {
                    let attachment = try await client.uploadDMAttachment(file: m.file, mimeType: m.mimeType, isVideo: m.isVideo)
                    id = try await client.sendMedia(attachmentId: attachment, thread: thread.id, replyTo: replyId, offlineId: item.otid)
                } else {
                    id = try await client.sendText(text, thread: thread.id, replyTo: replyId, offlineId: item.otid)
                }
                if let i = messages.firstIndex(where: { $0.offlineId == item.otid && $0.pending }) {
                    messages[i].pending = false
                    if let id { messages[i].id = id }
                }
                outgoing[item.otid] = nil
                thread.snippet = item.media.map { $0.isVideo ? "You sent a video" : "You sent a photo" } ?? text
                thread.lastActivity = .now
                thread.lastSenderIsViewer = true
                inbox?.update(thread)
            } catch {
                if let i = messages.firstIndex(where: { $0.offlineId == item.otid }) {
                    messages[i].pending = false
                    messages[i].failed = true
                }
                inbox?.report(error)
            }
        }
    }

    /// Removes a failed message and puts it back in the composer (text in the box, a photo or
    /// video in the tray).
    func retry(_ message: DMMessage) {
        if case .text(let t) = message.body {
            messages.removeAll { $0.id == message.id }
            draft = t
        } else if let otid = message.offlineId, let m = outgoing[otid] {
            messages.removeAll { $0.id == message.id }
            outgoing[otid] = nil
            staged.append(m)
        }
    }

    func toggleReaction(_ emoji: String, on message: DMMessage) async {
        guard let viewerId, let i = messages.firstIndex(where: { $0.id == message.id }) else { return }
        let mine = messages[i].reactions.first { $0.senderId == viewerId }
        let removing = mine?.emoji == emoji
        // One reaction per person: replace ours.
        messages[i].reactions.removeAll { $0.senderId == viewerId }
        if !removing { messages[i].reactions.append(DMReaction(emoji: emoji, senderId: viewerId)) }
        do {
            try await client.react(removing ? nil : emoji, previous: mine?.emoji, to: message.id, thread: thread.id)
        } catch {
            if let j = messages.firstIndex(where: { $0.id == message.id }) { messages[j].reactions = message.reactions }
            inbox?.report(error)
        }
    }

    func isPinned(_ message: DMMessage) -> Bool { thread.pinnedMessageIds.contains(message.id) }

    /// Pins a message to the top of the chat, or unpins it; undone if Instagram refuses.
    func togglePin(_ message: DMMessage) async {
        let before = thread.pinnedMessageIds
        let pin = !isPinned(message)
        if pin { thread.pinnedMessageIds.append(message.id) } else { thread.pinnedMessageIds.removeAll { $0 == message.id } }
        do {
            try await client.setPinned(pin, message: message.id, thread: thread.id)
            inbox?.show(pin ? "Pinned" : "Unpinned")
        } catch {
            thread.pinnedMessageIds = before
            inbox?.report(error)
        }
    }

    func unsend(_ message: DMMessage) async {
        guard let longId = thread.longId else { return }
        let backup = messages
        messages.removeAll { $0.id == message.id }
        do {
            try await client.unsend(message.id, longThreadId: longId)
        } catch {
            messages = backup
            inbox?.report(error)
        }
    }

    /// Tells Instagram we've read up to the newest message from the other side.
    /// After accepting a request.
    func markAccepted() { thread.isRequest = false }

    /// Accepts this chat's message request.
    func acceptRequest() async { await inbox?.accept(thread) }

    private func markRead() async {
        // Reading a request doesn't tell them (as on Instagram) until it's accepted.
        guard !thread.isRequest, let longId = thread.longId,
              let newest = messages.last(where: { $0.senderId != viewerId && !$0.pending }),
              newest.id != markedReadUpTo else { return }
        if let mine = viewerId.flatMap({ thread.readUpTo[$0] }), mine >= newest.sentAt { markedReadUpTo = newest.id; return }
        markedReadUpTo = newest.id
        try? await client.markRead(longThreadId: longId, message: newest)
    }

    func stop() {
        typingExpiry?.cancel()
        pendingRefresh?.cancel()
        if sentTyping?.on == true, let realtime = inbox?.realtime {
            let id = thread.id
            Task { try? await realtime.setTyping(false, threadId: id) }
        }
    }
}
